## Building WASM (Webassembly) files

1. Ensure Docker is installed

2. Change directories to the WASM directory

```sh
cd WASM
```

3. (Recommended) Use the pre-built Docker image to build a WASM file

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
docker run -v `pwd`:/src -w /src ghcr.io/webassembly/wasi-sdk /opt/wasi-sdk/bin/clang++ \
  --target=wasm32-wasip1-threads \
  -pthread \
  -Wl,--import-memory \
  -Wl,--export-memory \
  -Wl,--shared-memory \
  -Wl,--max-memory=67108864 \
  -I . \
  -o slam_main.wasm \
  slam_main.cpp utils/telemetry.cpp
```

1. Run the file using [Wasmtime](https://docs.wasmtime.dev/) or another runtime

```sh
wasmtime --wasi threads slam_main.wasm
```

## Motor control

Two helper APIs currently exist in C++ (see `WASM/motors.h`):

- `drive_percent(left_pct, right_pct, hold_ms)`  
  - Sends an immediate command. Percent is clamped to [-100, 100].  
  - `hold_ms` is metadata for the iOS host; it schedules an auto‑stop after that many milliseconds unless a newer command arrives. It does **not** block the calling thread.

- `drive_for(left_pct, right_pct, duration_ms, stop_after = true)`  
  - Convenience wrapper that calls `drive_percent`, then sleeps the calling thread for `duration_ms`, and optionally issues an explicit stop. Use this when you want a blocking “run then pause” pattern from C++ without managing sleeps yourself.

Summary: use `drive_percent` for non‑blocking, rapid updates (e.g., control loops); use `drive_for` when you need a timed motion with a guaranteed dwell before the next command.

## Autonomy Logic

TODO: Measure nominal extrinsics for sensors

- mapping
- localization
- planning/control
