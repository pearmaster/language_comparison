/* MQTT v5 benchmark client - C implementation (libmosquitto + cJSON). */
#include <mosquitto.h>
#include <mqtt_protocol.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "vendor/cJSON.h"

#define BROKER_HOST "localhost"
#define BROKER_PORT 1883
#define TOPIC_RECEIVE "test/receive"
#define TOPIC_SEND "test/send"
#define MESSAGES_FILE "/tmp/messages.txt"
#define PUBLISH_INTERVAL_S 5
#define DEFAULT_DURATION_S 120

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static void save_message(const char *message)
{
    FILE *f = fopen(MESSAGES_FILE, "a");
    if (!f) {
        perror("fopen " MESSAGES_FILE);
        return;
    }
    fputs(message, f);
    fputc('\n', f);
    fclose(f);
}

static void on_connect(struct mosquitto *mosq, void *userdata, int rc, int flags,
                       const mosquitto_property *props)
{
    (void)userdata; (void)flags; (void)props;
    if (rc != 0) {
        fprintf(stderr, "connect failed: %s\n", mosquitto_reason_string(rc));
        g_stop = 1;
        return;
    }
    mosquitto_subscribe_v5(mosq, NULL, TOPIC_RECEIVE, 0, 0, NULL);
}

static void on_message(struct mosquitto *mosq, void *userdata,
                       const struct mosquitto_message *msg,
                       const mosquitto_property *props)
{
    (void)mosq; (void)userdata;

    char *content_type = NULL;
    mosquitto_property_read_string(props, MQTT_PROP_CONTENT_TYPE, &content_type, false);
    if (!content_type) {
        return;
    }
    int is_json = strcmp(content_type, "application/json") == 0;
    free(content_type);
    if (!is_json) {
        return;
    }

    cJSON *root = cJSON_ParseWithLength((const char *)msg->payload, (size_t)msg->payloadlen);
    if (!root) {
        return;
    }
    const cJSON *message = cJSON_GetObjectItemCaseSensitive(root, "message");
    if (cJSON_IsString(message) && message->valuestring) {
        save_message(message->valuestring);
    }
    cJSON_Delete(root);
}

static void publish_time(struct mosquitto *mosq)
{
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "time", (double)time(NULL));
    char *payload = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!payload) {
        return;
    }

    mosquitto_property *props = NULL;
    mosquitto_property_add_string(&props, MQTT_PROP_CONTENT_TYPE, "application/json");
    mosquitto_publish_v5(mosq, NULL, TOPIC_SEND, (int)strlen(payload), payload, 0, false, props);
    mosquitto_property_free_all(&props);
    free(payload);
}

int main(int argc, char **argv)
{
    int duration_s = argc > 1 ? atoi(argv[1]) : DEFAULT_DURATION_S;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    mosquitto_lib_init();
    struct mosquitto *mosq = mosquitto_new("c-bench", true, NULL);
    if (!mosq) {
        fprintf(stderr, "mosquitto_new failed\n");
        return 1;
    }
    mosquitto_int_option(mosq, MOSQ_OPT_PROTOCOL_VERSION, MQTT_PROTOCOL_V5);
    mosquitto_connect_v5_callback_set(mosq, on_connect);
    mosquitto_message_v5_callback_set(mosq, on_message);

    int rc = mosquitto_connect_bind_v5(mosq, BROKER_HOST, BROKER_PORT, 30, NULL, NULL);
    if (rc != MOSQ_ERR_SUCCESS) {
        fprintf(stderr, "connect error: %s\n", mosquitto_strerror(rc));
        mosquitto_destroy(mosq);
        mosquitto_lib_cleanup();
        return 1;
    }

    time_t start = time(NULL);
    time_t next_publish = start + PUBLISH_INTERVAL_S;
    while (!g_stop) {
        time_t now = time(NULL);
        if (now - start >= duration_s) {
            break;
        }
        if (now >= next_publish) {
            publish_time(mosq);
            next_publish += PUBLISH_INTERVAL_S;
        }
        rc = mosquitto_loop(mosq, 1000, 1);
        if (rc != MOSQ_ERR_SUCCESS) {
            fprintf(stderr, "loop error: %s, reconnecting\n", mosquitto_strerror(rc));
            sleep(1);
            mosquitto_reconnect(mosq);
        }
    }

    mosquitto_disconnect_v5(mosq, 0, NULL);
    mosquitto_loop(mosq, 100, 1);
    mosquitto_destroy(mosq);
    mosquitto_lib_cleanup();
    return 0;
}
