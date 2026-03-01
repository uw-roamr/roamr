#!/bin/bash
filename="slam_main.cpp"
echo "building $filename"

docker run -v `pwd`:/src -w /src ghcr.io/webassembly/wasi-sdk /opt/wasi-sdk/bin/clang++ \
--target=wasm32-wasip1-threads \
-pthread \
-Wl,--import-memory \
-Wl,--export-memory \
-Wl,--shared-memory \
-Wl,--max-memory=67108864 \
-I. -Icore -Icontrols -Imapping -Isensors -Iutils \
-o slam_main.wasm \
$filename \
core/telemetry.cpp \
mapping/map.cpp mapping/map_update.cpp \
sensors/imu_calibration.cpp sensors/imu_preintegration.cpp