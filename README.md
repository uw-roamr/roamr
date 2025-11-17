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

See [WASM/README.md](WASM/README.md)