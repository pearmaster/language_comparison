//! MQTT v5 benchmark client - Rust implementation (rumqttc + serde_json).

use rumqttc::v5::mqttbytes::v5::{Packet, Publish, PublishProperties};
use rumqttc::v5::mqttbytes::QoS;
use rumqttc::v5::{Client, Event, MqttOptions, RecvTimeoutError};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};

use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const BROKER_HOST: &str = "localhost";
const BROKER_PORT: u16 = 1883;
const TOPIC_RECEIVE: &str = "test/receive";
const TOPIC_SEND: &str = "test/send";
const MESSAGES_FILE: &str = "/tmp/messages.txt";
const PUBLISH_INTERVAL: Duration = Duration::from_secs(5);
const DEFAULT_DURATION_S: u64 = 120;

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_sig: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

fn install_signal_handlers() {
    // SAFETY: the handler only touches an atomic, which is async-signal-safe.
    unsafe {
        libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
    }
}

fn save_message(message: &str) {
    match OpenOptions::new().append(true).create(true).open(MESSAGES_FILE) {
        Ok(mut f) => {
            if let Err(e) = writeln!(f, "{message}") {
                eprintln!("write {MESSAGES_FILE}: {e}");
            }
        }
        Err(e) => eprintln!("open {MESSAGES_FILE}: {e}"),
    }
}

fn handle_publish(publish: &Publish) {
    let content_type = publish
        .properties
        .as_ref()
        .and_then(|p| p.content_type.as_deref());
    if content_type != Some("application/json") {
        return;
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&publish.payload) else {
        return;
    };
    if let Some(message) = value.get("message").and_then(|m| m.as_str()) {
        save_message(message);
    }
}

fn publish_time(client: &Client) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let payload = serde_json::json!({ "time": now }).to_string();
    let props = PublishProperties {
        content_type: Some("application/json".to_string()),
        ..Default::default()
    };
    if let Err(e) = client.publish_with_properties(TOPIC_SEND, QoS::AtMostOnce, false, payload, props) {
        eprintln!("publish error: {e}");
    }
}

fn main() {
    let duration_s = std::env::args()
        .nth(1)
        .and_then(|a| a.parse().ok())
        .unwrap_or(DEFAULT_DURATION_S);

    install_signal_handlers();

    let mut options = MqttOptions::new("rust-bench", BROKER_HOST, BROKER_PORT);
    options.set_keep_alive(Duration::from_secs(30));
    // rumqttc sizes its in-flight table from this limit (default u16::MAX, which
    // pre-allocates ~14 MB). We only publish QoS 0, so a small table is plenty.
    options.set_outgoing_inflight_upper_limit(16);
    let (client, mut connection) = Client::new(options, 10);

    let start = Instant::now();
    let deadline = start + Duration::from_secs(duration_s);

    // Periodic publisher runs on its own thread; the main thread drives the event loop.
    let publisher_client = client.clone();
    let publisher = thread::spawn(move || {
        let mut next_publish = start + PUBLISH_INTERVAL;
        while !STOP.load(Ordering::SeqCst) && Instant::now() < deadline {
            let now = Instant::now();
            if now >= next_publish {
                publish_time(&publisher_client);
                next_publish += PUBLISH_INTERVAL;
                continue;
            }
            thread::sleep((next_publish - now).min(Duration::from_secs(1)));
        }
    });

    while !STOP.load(Ordering::SeqCst) && Instant::now() < deadline {
        match connection.recv_timeout(Duration::from_secs(1)) {
            Ok(Ok(Event::Incoming(Packet::ConnAck(_)))) => {
                if let Err(e) = client.subscribe(TOPIC_RECEIVE, QoS::AtMostOnce) {
                    eprintln!("subscribe error: {e}");
                }
            }
            Ok(Ok(Event::Incoming(Packet::Publish(publish)))) => handle_publish(&publish),
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                // rumqttc reconnects on the next poll; back off a little first.
                eprintln!("connection error: {e}, reconnecting");
                thread::sleep(Duration::from_secs(1));
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    STOP.store(true, Ordering::SeqCst);
    let _ = publisher.join();
    let _ = client.disconnect();
    // Give the event loop a moment to flush the DISCONNECT packet.
    let _ = connection.recv_timeout(Duration::from_millis(200));
}
