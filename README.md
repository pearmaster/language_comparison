# MQTT v5 client: C vs C++ vs Zig vs Rust vs Python

Five implementations of the same small embedded-Linux style daemon, built to
compare **binary size** and **memory usage** across languages.

## What every program does

1. Connects to the MQTT broker on `localhost:1883` using **MQTT v5**, no credentials.
2. Subscribes to `test/receive`.
3. For every message on that topic it reads the MQTT v5 **Content-Type** publish
   property. If it is `application/json` the payload is JSON-decoded and, if the
   object has a string property `message`, that string is appended as one line
   to `/tmp/messages.txt`. Anything else is ignored.
4. Every 5 seconds it publishes `{"time":<unix epoch seconds>}` to `test/send`
   (also tagged with Content-Type `application/json`).
5. Exits cleanly after 2 minutes. The duration can be overridden with the first
   command-line argument (seconds), which the Taskfile uses via `DURATION=`.

| dir       | language | MQTT library                        | JSON library          | build                                   |
|-----------|----------|-------------------------------------|-----------------------|-----------------------------------------|
| `c/`      | C11      | libmosquitto (system)               | cJSON 1.7.18 (vendored) | `gcc -Os`, gc-sections, stripped       |
| `cpp/`    | C++17    | libmosquitto (system, C API)        | RapidJSON (system headers) | `g++ -Os`, gc-sections, stripped    |
| `zig/`    | Zig 0.17 | libmosquitto via translate-c step   | `std.json`            | `zig build -Doptimize=small`     |
| `rust/`   | Rust     | rumqttc 0.25 (pure Rust, no TLS)    | serde_json            | release, `opt-level=s`, LTO, stripped   |
| `python/` | Python 3 | paho-mqtt 2.1                       | `json` (stdlib)       | venv in `python/.venv`                  |

## Prerequisites

- A running Mosquitto broker on `localhost:1883` (`mosquitto` package) plus
  `mosquitto_pub` / `mosquitto_sub` (`mosquitto-clients`) for the test traffic.
- `libmosquitto-dev` and `rapidjson-dev` headers, `gcc`, `g++`, `make`.
- `cargo` / `rustc`.
- `uv` (creates the Python venv). Python 3.
- [Task](https://taskfile.dev) (`task`).
- Zig is **not** required system-wide: `task setup:zig` downloads 0.17.0 into
  `.tools/zig/` (no root needed).

## Usage

```sh
task setup            # one time: Zig toolchain + Python venv
task build            # build C, C++, Zig and Rust
task bench            # run all five for 2 min each (sequentially), then print the table
task bench DURATION=20   # same, but 20 s per program
task bench:rust       # one language only
task report           # re-print the comparison table from results/
task sizes            # on-disk size of binaries, their shared libs and the Python runtime
task run:c            # run a program without measurement
task send MESSAGE=hi  # publish {"message":"hi"} to test/receive with Content-Type application/json
task listen           # watch test/send
task messages         # cat /tmp/messages.txt
```

## How memory is measured

`scripts/measure.sh` runs one program and, while it runs:

- samples `/proc/<pid>/smaps_rollup` every 0.5 s for **RSS**, **PSS**, and the
  anonymous / file-backed split of PSS;
- reads `VmHWM` from `/proc/<pid>/status` at each sample (kernel-tracked peak RSS);
- wraps the program in GNU `time` for wall / user / sys CPU time and `ru_maxrss`;
- feeds `test/receive` with `scripts/stimulus.sh` (a JSON message every 2 s, plus
  periodic messages that must be *ignored*: missing Content-Type, `text/plain`,
  and JSON without a `message` property);
- records everything published on `test/send` with `mosquitto_sub`.

Results land in `results/<lang>/` (`summary.env`, `samples.csv`, `sent.log`,
`messages.txt`, `time.txt`, logs) and `scripts/report.sh` turns them into
`results/summary.md`.

PSS is the number to look at on a device that runs several processes: pages of
shared libraries (libc, OpenSSL pulled in by libmosquitto, libstdc++, libpython)
are divided between the processes that map them, while RSS charges each process
the full amount.

## Notes on fairness

- C, C++ and Zig all link the same system `libmosquitto`, which itself links
  OpenSSL, zlib and zstd. Those shared libraries are counted in the "shared libs"
  size column but are shared with any other process on the device that uses them.
- Rust uses a pure-Rust client (rumqttc) with TLS features disabled, so its
  binary is statically self-contained apart from libc. rumqttc pre-allocates an
  in-flight table sized by `set_outgoing_inflight_upper_limit` (default 65535
  entries, roughly 14 MB); the Rust program sets it to 16.
- Python's "artifact" is just `main.py`; the interpreter, its stdlib and the
  paho-mqtt package are needed on the device as well. `task sizes` prints them.
- All programs poll the socket with a 1 s timeout in a single loop (Rust uses a
  second thread for the 5 s publisher because rumqttc's event loop owns the
  connection).

## Results (x86_64, 2 min each, Ubuntu, Mosquitto 2.0.22)

| language | artifact | shared libs (non-libc) | peak RSS | peak PSS | final PSS (anon / file) | threads | CPU (user+sys) |
|---|---:|---:|---:|---:|---:|---:|---:|
| c | 22.1 KiB | 8.1 MiB | 4.6 MiB | 1.0 MiB | 1.0 MiB (0.7 / 0.2) | 1 | 0.00 s |
| cpp | 46.3 KiB | 10.7 MiB | 6.7 MiB | 1.3 MiB | 1.3 MiB (0.8 / 0.4) | 1 | 0.00 s |
| zig | 184.6 KiB | 8.1 MiB | 5.0 MiB | 1.4 MiB | 1.3 MiB (1.0 / 0.3) | 1 | 0.01 s |
| rust | 586.0 KiB | 0 (static apart from libc) | 3.1 MiB | 0.8 MiB | 0.8 MiB (0.3 / 0.5) | 2 | 0.01 s |
| python | 2.8 KiB (+ 7 MiB interpreter, 56 MiB stdlib, 0.7 MiB paho) | – | 25.9 MiB | 19.9 MiB | 19.9 MiB (13.0 / 6.9) | 1 | 0.11 s |

All five saved every valid message (59–60 over 2 min), ignored every invalid one, and published 23 time messages.
The "shared libs" column for C/C++/Zig is libmosquitto plus the OpenSSL/zlib/zstd it drags in; on a device these pages are shared with every other process that uses them, which is why peak PSS is ~1 MiB while peak RSS is 4–7 MiB.
