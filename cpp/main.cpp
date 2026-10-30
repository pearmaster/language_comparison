// MQTT v5 benchmark client - C++ implementation (libmosquitto + RapidJSON).
#include <mosquitto.h>
#include <mqtt_protocol.h>
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>

#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

namespace {

constexpr const char *kBrokerHost = "localhost";
constexpr int kBrokerPort = 1883;
constexpr const char *kTopicReceive = "test/receive";
constexpr const char *kTopicSend = "test/send";
constexpr const char *kMessagesFile = "/tmp/messages.txt";
constexpr auto kPublishInterval = std::chrono::seconds(5);
constexpr int kDefaultDurationS = 120;

volatile std::sig_atomic_t g_stop = 0;

void on_signal(int) { g_stop = 1; }

void save_message(const std::string &message)
{
    std::ofstream out(kMessagesFile, std::ios::app);
    if (!out) {
        std::cerr << "cannot open " << kMessagesFile << '\n';
        return;
    }
    out << message << '\n';
}

class MqttClient {
public:
    MqttClient()
    {
        mosquitto_lib_init();
        mosq_ = mosquitto_new("cpp-bench", true, this);
        if (!mosq_) {
            throw std::runtime_error("mosquitto_new failed");
        }
        mosquitto_int_option(mosq_, MOSQ_OPT_PROTOCOL_VERSION, MQTT_PROTOCOL_V5);
        mosquitto_connect_v5_callback_set(mosq_, &MqttClient::on_connect);
        mosquitto_message_v5_callback_set(mosq_, &MqttClient::on_message);
    }

    ~MqttClient()
    {
        mosquitto_destroy(mosq_);
        mosquitto_lib_cleanup();
    }

    MqttClient(const MqttClient &) = delete;
    MqttClient &operator=(const MqttClient &) = delete;

    bool connect()
    {
        int rc = mosquitto_connect_bind_v5(mosq_, kBrokerHost, kBrokerPort, 30, nullptr, nullptr);
        if (rc != MOSQ_ERR_SUCCESS) {
            std::cerr << "connect error: " << mosquitto_strerror(rc) << '\n';
            return false;
        }
        return true;
    }

    void loop(int timeout_ms)
    {
        int rc = mosquitto_loop(mosq_, timeout_ms, 1);
        if (rc != MOSQ_ERR_SUCCESS) {
            std::cerr << "loop error: " << mosquitto_strerror(rc) << ", reconnecting\n";
            std::this_thread::sleep_for(std::chrono::seconds(1));
            mosquitto_reconnect(mosq_);
        }
    }

    void disconnect()
    {
        mosquitto_disconnect_v5(mosq_, 0, nullptr);
        mosquitto_loop(mosq_, 100, 1);
    }

    void publish_time()
    {
        const auto now = std::chrono::system_clock::now();
        const auto epoch_s =
            std::chrono::duration_cast<std::chrono::seconds>(now.time_since_epoch()).count();

        rapidjson::StringBuffer buf;
        rapidjson::Writer<rapidjson::StringBuffer> writer(buf);
        writer.StartObject();
        writer.Key("time");
        writer.Int64(epoch_s);
        writer.EndObject();

        mosquitto_property *props = nullptr;
        mosquitto_property_add_string(&props, MQTT_PROP_CONTENT_TYPE, "application/json");
        mosquitto_publish_v5(mosq_, nullptr, kTopicSend, static_cast<int>(buf.GetSize()),
                             buf.GetString(), 0, false, props);
        mosquitto_property_free_all(&props);
    }

private:
    static void on_connect(struct mosquitto *mosq, void *, int rc, int, const mosquitto_property *)
    {
        if (rc != 0) {
            std::cerr << "connect failed: " << mosquitto_reason_string(rc) << '\n';
            g_stop = 1;
            return;
        }
        mosquitto_subscribe_v5(mosq, nullptr, kTopicReceive, 0, 0, nullptr);
    }

    static void on_message(struct mosquitto *, void *, const struct mosquitto_message *msg,
                           const mosquitto_property *props)
    {
        char *content_type = nullptr;
        mosquitto_property_read_string(props, MQTT_PROP_CONTENT_TYPE, &content_type, false);
        if (!content_type) {
            return;
        }
        const bool is_json = std::strcmp(content_type, "application/json") == 0;
        std::free(content_type);
        if (!is_json) {
            return;
        }

        rapidjson::Document doc;
        doc.Parse(static_cast<const char *>(msg->payload), static_cast<size_t>(msg->payloadlen));
        if (doc.HasParseError() || !doc.IsObject()) {
            return;
        }
        const auto it = doc.FindMember("message");
        if (it != doc.MemberEnd() && it->value.IsString()) {
            save_message(std::string(it->value.GetString(), it->value.GetStringLength()));
        }
    }

    struct mosquitto *mosq_ = nullptr;
};

} // namespace

int main(int argc, char **argv)
{
    using clock = std::chrono::steady_clock;
    const int duration_s = argc > 1 ? std::atoi(argv[1]) : kDefaultDurationS;

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    try {
        MqttClient client;
        if (!client.connect()) {
            return 1;
        }

        const auto start = clock::now();
        const auto deadline = start + std::chrono::seconds(duration_s);
        auto next_publish = start + kPublishInterval;

        while (!g_stop && clock::now() < deadline) {
            if (clock::now() >= next_publish) {
                client.publish_time();
                next_publish += kPublishInterval;
            }
            client.loop(1000);
        }
        client.disconnect();
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
    return 0;
}
