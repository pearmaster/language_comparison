const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.17 removed @cImport; C headers are translated by a build step instead.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mqtt_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = optimize != .debug,
            .imports = &.{
                .{ .name = "c", .module = translate_c.createModule() },
            },
        }),
    });
    // System libmosquitto (same library the C and C++ builds use).
    exe.root_module.linkSystemLibrary("mosquitto", .{});

    b.installArtifact(exe);
}
