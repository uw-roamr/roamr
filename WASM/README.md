## Building WASM (Webassembly) files

1. Ensure Docker is installed


2. (Recommended) Use the pre-built Docker image to build a WASM file

Build any C++ file with:
```sh
docker run -v `pwd`:/src -w /src ghcr.io/webassembly/wasi-sdk /opt/wasi-sdk/bin/clang \
--target=wasm32-wasi \
-o <out-filename> \
<filename>
```
The `--target=wasm32-wasi` flag adds support for I/O functionality. Alternatively, the `--target=wasm32-wasip1-threads` enables experimental threading.

Examples:
```sh
./build_wasm.sh
```

## Motor control

Two helper APIs currently exist in C++ (see `WASM/motors.h`):

- `drive_percent(left_pct, right_pct, hold_ms)`
  - Sends an immediate command. Percent is clamped to [-100, 100].
  - `hold_ms` is metadata for the iOS host; it schedules an auto‑stop after that many milliseconds unless a newer command arrives. It does **not** block the calling thread.

- `drive_for(left_pct, right_pct, duration_ms, stop_after = true)`
  - Convenience wrapper that calls `drive_percent`, then sleeps the calling thread for `duration_ms`, and optionally issues an explicit stop. Use this when you want a blocking “run then pause” pattern from C++ without managing sleeps yourself.

Summary: use `drive_percent` for non‑blocking, rapid updates (e.g., control loops); use `drive_for` when you need a timed motion with a guaranteed dwell before the next command.

## Wheel odometry POC

`slam_main.cpp` includes a wheel-odometry dead-reckoning thread:

- pulls queued BLE wheel samples from host via `read_wheel_odometry(...)`
- integrates `(dl_ticks, dr_ticks)` into `(x, y, yaw)`
- logs the integrated pose through existing `rerun_log_pose(...)`

The host side buffers incoming BLE samples and only pops them when WASM asks, so odometry accrues safely between WASM polling calls.

## Autonomy Logic

TODO: Measure nominal extrinsics for sensors

- mapping
- localization
- planning/control
