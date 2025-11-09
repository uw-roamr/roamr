# ROAMR: Really Opensource Autonomous Mobile Robot

Mobile phones and mobile robots have many common requirements:

- performant sensors (cameras, IMUs, LiDAR, GPS) and sensor fusion
- networking capabilities (WiFi, Bluetooth Low Energy, LTE)
- energy efficiency

What if we turned the iPhone into a robot?

## Architecture

Goal:

- make systems integration of software components simple

Ideas:
- WASM binaries to decouple autonomy logic
- Websockets for performant communication

## Setup

```sh
pip install pre-commit
pre-commit
```

## Localization Demo

```
cd WASM

~/wasi-sdk-27.0-arm64-macos/bin/clang --target=wasm32 -O2 -nostdlib \
  -Wl,--no-entry \
  -Wl,--export=reset_poses \
  -Wl,--export=set_pose \
  -Wl,--export=draw_pose_map \
  -Wl,--export=get_image_width \
  -Wl,--export=get_image_height \
  -Wl,--export=get_image_pixel_u32 \
  -Wl,--export=log_pose_f32 \
  -o map.wasm map.cpp
```