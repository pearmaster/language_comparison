#!/usr/bin/env bash
# Prints a comparison table from results/*/summary.env and writes results/summary.md
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
order="c cpp zig rust python"
md="$root/results/summary.md"

kb() { awk -v v="$1" 'BEGIN{printf "%.1f", v/1024}'; }
b()  { awk -v v="$1" 'BEGIN{ if (v>=1048576) printf "%.1f MiB", v/1048576; else printf "%.1f KiB", v/1024}'; }

{
    echo "| language | artifact | shared libs (non-libc) | peak RSS | peak PSS | final PSS (anon / file) | threads | CPU (user+sys) | saved msgs | sent msgs |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    for n in $order; do
        f="$root/results/$n/summary.env"
        [ -f "$f" ] || continue
        unset peak_rss_kb peak_pss_kb final_pss_kb final_pss_anon_kb final_pss_file_kb threads user_s sys_s artifact_bytes shared_libs_bytes messages_saved messages_saved_wrongly time_messages_sent exit_code
        . "$f"
        cpu=$(awk -v u="$user_s" -v s="$sys_s" 'BEGIN{printf "%.2f s", u+s}')
        status=""; [ "$exit_code" != "0" ] && status=" (exit $exit_code)"
        echo "| $n$status | $(b "$artifact_bytes") | $(b "$shared_libs_bytes") | $(kb "$peak_rss_kb") MiB | $(kb "$peak_pss_kb") MiB | $(kb "$final_pss_kb") MiB ($(kb "$final_pss_anon_kb") / $(kb "$final_pss_file_kb")) | $threads | $cpu | $messages_saved (wrong: $messages_saved_wrongly) | $time_messages_sent |"
    done
    echo
    echo "Notes:"
    echo "- RSS/PSS are from /proc/<pid>/status (VmHWM) and /proc/<pid>/smaps_rollup; PSS splits shared library pages across processes."
    echo "- 'artifact' is the compiled binary, or main.py for Python; see results/<lang>/summary.env for the shared libraries counted."
    echo "- Python additionally needs the interpreter on the device (see 'task sizes' for the interpreter and venv footprint)."
} | tee "$md"
