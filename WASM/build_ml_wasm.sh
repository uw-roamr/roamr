#!/bin/bash
set -euo pipefail

filename="${1:-stop_sign_main.cpp}"
output_name="$(basename "${filename%.cpp}").wasm"

echo "building $filename"

docker run -v "$(pwd)":/src -w /src ghcr.io/webassembly/wasi-sdk /opt/wasi-sdk/bin/clang++ \
--target=wasm32-wasip1-threads \
-pthread \
-fno-exceptions \
-fno-rtti \
-Wl,--import-memory \
-Wl,--export-memory \
-Wl,--shared-memory \
-Wl,--max-memory=67108864 \
-I. -Icore -Icontrols -Isensors -Iutils -Iml \
-o "$output_name" \
"$filename" \
core/telemetry.cpp
