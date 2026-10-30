#!/usr/bin/env bash
# Publishes test traffic to test/receive for DURATION seconds so the
# benchmarked program's receive path is exercised.
#
# Every 2 s: a JSON message with content-type application/json  -> must be saved
# Every 10 s additionally:
#   - a JSON-looking payload WITHOUT a content-type property      -> must be ignored
#   - a text/plain payload                                        -> must be ignored
#   - an application/json payload with no "message" property      -> must be ignored
set -u
duration=${1:-120}
host=${BROKER_HOST:-localhost}
i=0
end=$((SECONDS + duration))
sleep 1
while [ "$SECONDS" -lt "$end" ]; do
    i=$((i + 1))
    mosquitto_pub -V 5 -h "$host" -t test/receive \
        -D publish content-type application/json \
        -m "{\"message\":\"hello $i\",\"seq\":$i}"
    if [ $((i % 5)) -eq 0 ]; then
        mosquitto_pub -V 5 -h "$host" -t test/receive -m "{\"message\":\"NO-CONTENT-TYPE $i\"}"
        mosquitto_pub -V 5 -h "$host" -t test/receive -D publish content-type text/plain -m "{\"message\":\"TEXT-PLAIN $i\"}"
        mosquitto_pub -V 5 -h "$host" -t test/receive -D publish content-type application/json -m "{\"other\":\"NO-MESSAGE $i\"}"
    fi
    sleep 2
done
