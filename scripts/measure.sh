#!/usr/bin/env bash
# Runs one benchmark program under memory measurement.
#
# usage: measure.sh <name> <artifact> <duration-s> -- <command> [args...]
#
#   name      label used for results/<name>/
#   artifact  file whose on-disk size is reported (binary, or main.py for Python)
#
# What is collected:
#   - peak RSS (VmHWM, kernel-tracked high-water mark) and GNU time's ru_maxrss
#   - PSS / RSS / anon / file-backed memory sampled from /proc/<pid>/smaps_rollup
#     every 0.5 s (PSS shares library pages fairly between processes, which is
#     the more honest number on an embedded system running several daemons)
#   - wall / user / sys CPU time
#   - size of the artifact and of the shared libraries it links (ldd)
#   - functional check: lines saved to /tmp/messages.txt and messages seen on test/send
set -u
name=$1; artifact=$2; duration=$3; shift 3
[ "${1:-}" = "--" ] && shift

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/results/$name"
rm -rf "$out"; mkdir -p "$out"
samples="$out/samples.csv"
host=${BROKER_HOST:-localhost}

rm -f /tmp/messages.txt

# Observe what the program publishes on test/send.
mosquitto_sub -V 5 -h "$host" -t test/send -F '%U %t %p' > "$out/sent.log" 2>/dev/null &
sub_pid=$!

# Feed test/receive in the background.
"$root/scripts/stimulus.sh" "$duration" > /dev/null 2>&1 &
stim_pid=$!

echo "[$name] running: $* (for ${duration}s)"
/usr/bin/time -f "wall_s=%e\nuser_s=%U\nsys_s=%S\nmaxrss_kb=%M" -o "$out/time.txt" \
    "$@" > "$out/stdout.log" 2> "$out/stderr.log" &
time_pid=$!

# The program is GNU time's child.
pid=""
for _ in $(seq 1 50); do
    pid=$(pgrep -P "$time_pid" | head -n1)
    [ -n "$pid" ] && break
    sleep 0.1
done

echo "t_s,rss_kb,pss_kb,pss_anon_kb,pss_file_kb,vmhwm_kb,threads" > "$samples"
t0=$(date +%s.%N)
peak_pss=0; peak_rss=0; last_hwm=0; last_threads=0; last_pss=0; last_rss=0; last_anon=0; last_file=0
while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
    line=$(awk '/^Rss:/{r=$2} /^Pss:/{p=$2} /^Pss_Anon:/{a=$2} /^Pss_File:/{f=$2} END{print r+0, p+0, a+0, f+0}' \
           "/proc/$pid/smaps_rollup" 2>/dev/null)
    st=$(awk '/^VmHWM:/{h=$2} /^Threads:/{t=$2} END{print h+0, t+0}' "/proc/$pid/status" 2>/dev/null)
    if [ -n "$line" ] && [ -n "$st" ]; then
        read -r rss pss anon file <<< "$line"
        read -r hwm thr <<< "$st"
        if [ "$rss" -gt 0 ]; then
            t=$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN{printf "%.1f", a-b}')
            echo "$t,$rss,$pss,$anon,$file,$hwm,$thr" >> "$samples"
            [ "$pss" -gt "$peak_pss" ] && peak_pss=$pss
            [ "$rss" -gt "$peak_rss" ] && peak_rss=$rss
            last_hwm=$hwm; last_threads=$thr; last_pss=$pss; last_rss=$rss; last_anon=$anon; last_file=$file
        fi
    fi
    sleep 0.5
done
wait "$time_pid"; rc=$?

kill "$stim_pid" 2>/dev/null; wait "$stim_pid" 2>/dev/null
sleep 0.3
kill "$sub_pid" 2>/dev/null; wait "$sub_pid" 2>/dev/null

# Functional results.
saved=$(wc -l < /tmp/messages.txt 2>/dev/null || echo 0)
bad=$(grep -cE 'NO-CONTENT-TYPE|TEXT-PLAIN|NO-MESSAGE' /tmp/messages.txt 2>/dev/null); bad=${bad:-0}
sent=$(wc -l < "$out/sent.log")
sent_ok=$(grep -cE '\{"time":[0-9]+\}' "$out/sent.log" || true)
cp /tmp/messages.txt "$out/messages.txt" 2>/dev/null || true

# Sizes.
artifact_bytes=$(stat -c %s "$artifact")
libs_bytes=0; libs=""
if ldd "$artifact" >/dev/null 2>&1; then
    while read -r lib; do
        [ -f "$lib" ] || continue
        case "$(basename "$lib")" in
            libc.so*|ld-linux*|linux-vdso*|libm.so*|libpthread*|libdl*|librt*|libgcc_s*) continue ;;
        esac
        real=$(readlink -f "$lib")
        sz=$(stat -c %s "$real")
        libs_bytes=$((libs_bytes + sz))
        libs="$libs $(basename "$lib")=$sz"
    done < <(ldd "$artifact" | awk '/=>/ {print $3}')
fi

. "$out/time.txt"
{
    echo "name=$name"
    echo "command='$*'"
    echo "duration_s=$duration"
    echo "exit_code=$rc"
    echo "artifact=$artifact"
    echo "artifact_bytes=$artifact_bytes"
    echo "shared_libs_bytes=$libs_bytes"
    echo "shared_libs='$libs'"
    echo "peak_rss_kb=$last_hwm"
    echo "time_maxrss_kb=$maxrss_kb"
    echo "peak_sampled_rss_kb=$peak_rss"
    echo "peak_pss_kb=$peak_pss"
    echo "final_rss_kb=$last_rss"
    echo "final_pss_kb=$last_pss"
    echo "final_pss_anon_kb=$last_anon"
    echo "final_pss_file_kb=$last_file"
    echo "threads=$last_threads"
    echo "wall_s=$wall_s"
    echo "user_s=$user_s"
    echo "sys_s=$sys_s"
    echo "messages_saved=$saved"
    echo "messages_saved_wrongly=$bad"
    echo "time_messages_sent=$sent"
    echo "time_messages_valid_json=$sent_ok"
} > "$out/summary.env"

echo "[$name] exit=$rc peakRSS=${last_hwm}kB peakPSS=${peak_pss}kB saved=$saved (wrong=$bad) sent=$sent cpu=$(awk -v u="$user_s" -v s="$sys_s" 'BEGIN{print u+s}')s"
[ "$rc" -eq 0 ] || { echo "[$name] stderr:"; cat "$out/stderr.log"; }
exit "$rc"
