//! MQTT v5 benchmark client - Zig implementation (libmosquitto via translate-c + std.json).
const std = @import("std");

// C headers (libmosquitto, libc) translated by the build step, see src/c.h.
const c = @import("c");

const broker_host = "localhost";
const broker_port: c_int = 1883;
const topic_receive = "test/receive";
const topic_send = "test/send";
const messages_file = "/tmp/messages.txt";
const publish_interval_s: c.time_t = 5;
const default_duration_s: c.time_t = 120;

// libc is linked anyway (for libmosquitto), so use its allocator.
const allocator = std.heap.c_allocator;

var g_stop = std.atomic.Value(bool).init(false);

fn onSignal(_: c_int) callconv(.c) void {
    g_stop.store(true, .seq_cst);
}

fn saveMessage(message: []const u8) void {
    const f = c.fopen(messages_file, "a") orelse {
        std.debug.print("cannot open {s}\n", .{messages_file});
        return;
    };
    defer _ = c.fclose(f);
    _ = c.fwrite(message.ptr, 1, message.len, f);
    _ = c.fputc('\n', f);
}

fn onConnect(
    mosq: ?*c.struct_mosquitto,
    _: ?*anyopaque,
    rc: c_int,
    _: c_int,
    _: ?*const c.mosquitto_property,
) callconv(.c) void {
    if (rc != 0) {
        std.debug.print("connect failed: {s}\n", .{c.mosquitto_reason_string(rc)});
        g_stop.store(true, .seq_cst);
        return;
    }
    _ = c.mosquitto_subscribe_v5(mosq, null, topic_receive, 0, 0, null);
}

fn onMessage(
    _: ?*c.struct_mosquitto,
    _: ?*anyopaque,
    msg: [*c]const c.struct_mosquitto_message,
    props: ?*const c.mosquitto_property,
) callconv(.c) void {
    var content_type: [*c]u8 = null;
    _ = c.mosquitto_property_read_string(props, c.MQTT_PROP_CONTENT_TYPE, &content_type, false);
    if (content_type == null) return;
    defer c.free(content_type);
    if (!std.mem.eql(u8, std.mem.span(content_type), "application/json")) return;

    const payload_ptr: [*]const u8 = @ptrCast(msg.*.payload orelse return);
    const payload = payload_ptr[0..@intCast(msg.*.payloadlen)];

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const message = parsed.value.object.get("message") orelse return;
    if (message != .string) return;
    saveMessage(message.string);
}

fn publishTime(mosq: ?*c.struct_mosquitto) void {
    const TimeMessage = struct { time: i64 };
    const value = TimeMessage{ .time = @intCast(c.time(null)) };
    const payload = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return;
    defer allocator.free(payload);

    var props: ?*c.mosquitto_property = null;
    _ = c.mosquitto_property_add_string(&props, c.MQTT_PROP_CONTENT_TYPE, "application/json");
    _ = c.mosquitto_publish_v5(mosq, null, topic_send, @intCast(payload.len), payload.ptr, 0, false, props);
    c.mosquitto_property_free_all(&props);
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const duration_s: c.time_t = if (args.len > 1)
        std.fmt.parseInt(c.time_t, args[1], 10) catch default_duration_s
    else
        default_duration_s;

    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);

    _ = c.mosquitto_lib_init();
    defer _ = c.mosquitto_lib_cleanup();

    const mosq = c.mosquitto_new("zig-bench", true, null) orelse {
        std.debug.print("mosquitto_new failed\n", .{});
        return 1;
    };
    defer c.mosquitto_destroy(mosq);

    _ = c.mosquitto_int_option(mosq, c.MOSQ_OPT_PROTOCOL_VERSION, c.MQTT_PROTOCOL_V5);
    c.mosquitto_connect_v5_callback_set(mosq, onConnect);
    c.mosquitto_message_v5_callback_set(mosq, onMessage);

    var rc = c.mosquitto_connect_bind_v5(mosq, broker_host, broker_port, 30, null, null);
    if (rc != c.MOSQ_ERR_SUCCESS) {
        std.debug.print("connect error: {s}\n", .{c.mosquitto_strerror(rc)});
        return 1;
    }

    const start = c.time(null);
    var next_publish = start + publish_interval_s;
    while (!g_stop.load(.seq_cst)) {
        const now = c.time(null);
        if (now - start >= duration_s) break;
        if (now >= next_publish) {
            publishTime(mosq);
            next_publish += publish_interval_s;
        }
        rc = c.mosquitto_loop(mosq, 1000, 1);
        if (rc != c.MOSQ_ERR_SUCCESS) {
            std.debug.print("loop error: {s}, reconnecting\n", .{c.mosquitto_strerror(rc)});
            _ = c.sleep(1);
            _ = c.mosquitto_reconnect(mosq);
        }
    }

    _ = c.mosquitto_disconnect_v5(mosq, 0, null);
    _ = c.mosquitto_loop(mosq, 100, 1);
    return 0;
}
