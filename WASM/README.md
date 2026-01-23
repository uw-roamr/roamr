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
docker run -v `pwd`:/src -w /src ghcr.io/webassembly/wasi-sdk /opt/wasi-sdk/bin/clang++ \
--target=wasm32-wasip1-threads \
-pthread \
-Wl,--import-memory \
-Wl,--export-memory \
-Wl,--shared-memory \
-Wl,--max-memory=67108864 \
-o slam_main.wasm slam_main.cpp telemetry.cpp
```

1. Run the file using [Wasmtime](https://docs.wasmtime.dev/) or another runtime

```sh
wasmtime --wasi threads slam_main.wasm
```
## Autonomy Logic

TODO: Measure nominal extrinsics for sensors

- mapping
- localization
- planning/control
