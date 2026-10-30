"""MQTT v5 benchmark client - Python implementation (paho-mqtt + json)."""

import json
import signal
import sys
import time

import paho.mqtt.client as mqtt
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties

BROKER_HOST = "localhost"
BROKER_PORT = 1883
TOPIC_RECEIVE = "test/receive"
TOPIC_SEND = "test/send"
MESSAGES_FILE = "/tmp/messages.txt"
PUBLISH_INTERVAL_S = 5
DEFAULT_DURATION_S = 120

stop = False


def on_signal(signum, frame):
    global stop
    stop = True


def save_message(message: str) -> None:
    with open(MESSAGES_FILE, "a", encoding="utf-8") as f:
        f.write(message)
        f.write("\n")


def on_connect(client, userdata, flags, reason_code, properties):
    global stop
    if reason_code.is_failure:
        print(f"connect failed: {reason_code}", file=sys.stderr)
        stop = True
        return
    client.subscribe(TOPIC_RECEIVE, qos=0)


def on_message(client, userdata, msg):
    content_type = getattr(msg.properties, "ContentType", None)
    if content_type != "application/json":
        return
    try:
        obj = json.loads(msg.payload)
    except (ValueError, UnicodeDecodeError):
        return
    if isinstance(obj, dict):
        message = obj.get("message")
        if isinstance(message, str):
            save_message(message)


def publish_time(client) -> None:
    payload = json.dumps({"time": int(time.time())}, separators=(",", ":"))
    props = Properties(PacketTypes.PUBLISH)
    props.ContentType = "application/json"
    client.publish(TOPIC_SEND, payload, qos=0, properties=props)


def main() -> int:
    duration_s = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DURATION_S

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id="python-bench",
        protocol=mqtt.MQTTv5,
    )
    client.on_connect = on_connect
    client.on_message = on_message

    try:
        client.connect(BROKER_HOST, BROKER_PORT, keepalive=30)
    except OSError as e:
        print(f"connect error: {e}", file=sys.stderr)
        return 1

    start = time.monotonic()
    next_publish = start + PUBLISH_INTERVAL_S
    while not stop and time.monotonic() - start < duration_s:
        if time.monotonic() >= next_publish:
            publish_time(client)
            next_publish += PUBLISH_INTERVAL_S
        rc = client.loop(timeout=1.0)
        if rc != mqtt.MQTT_ERR_SUCCESS:
            print(f"loop error: {mqtt.error_string(rc)}, reconnecting", file=sys.stderr)
            time.sleep(1)
            try:
                client.reconnect()
            except OSError:
                pass

    client.disconnect()
    client.loop(timeout=0.1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
