#!/bin/bash
docker run -v `pwd`:/src -w /src ghcr.io/webassembly/wasi-sdk /opt/wasi-sdk/bin/clang++ \
  --target=wasm32-wasip1-threads \
  -pthread \
    -fno-exceptions \
  -Wl,--import-memory \
  -Wl,--export-memory \
  -Wl,--shared-memory \
  -Wl,--max-memory=67108864 \
  -I . \
  -o slam_main.wasm \
  slam_main.cpp utils/telemetry.cpp \
  frontend/corner_detection.cpp \
  sensors/lidar_camera.cpp