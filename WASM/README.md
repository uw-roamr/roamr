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

Motor helper APIs exist in C++ (see `WASM/controls/motors.h`):

- `drive_percent(left_pct, right_pct, hold_ms)`
  - Sends an immediate command. Percent is clamped to [-100, 100].
  - `hold_ms` is metadata for the iOS host; it schedules an auto‑stop after that many milliseconds unless a newer command arrives. It does **not** block the calling thread.

- `drive_for(left_pct, right_pct, duration_ms, stop_after = true)`
  - Convenience wrapper that calls `drive_percent`, then sleeps the calling thread for `duration_ms`, and optionally issues an explicit stop. Use this when you want a blocking “run then pause” pattern from C++ without managing sleeps yourself.

- `drive_twist(v_mps, omega_rad_s, odom, hold_ms)`
  - Converts body twist `(v, omega)` into left/right wheel speed setpoints and runs a closed-loop wheel-speed controller.
  - Inputs are clamped to `|v| <= 0.3 m/s` and `|omega| <= pi rad/s`.
  - Wheel speed feedback is computed from wheel odometry deltas `(dl_ticks, dr_ticks, sample_period_ms)` and mapped back to motor percent outputs.
  - Call it once per fresh odometry sample for stable control updates.

- `drive_twist_for(v_mps, omega_rad_s, duration_ms, stop_after = true)`
  - Blocking twist helper that internally polls wheel odometry and repeatedly calls `drive_twist`.
  - Use this for simple motion demos that should resemble `drive_for(...)`.

Summary: use `drive_percent` for direct open-loop commands, `drive_twist` for per-sample closed-loop updates, and `drive_for` / `drive_twist_for` for simple blocking demo motions.

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
