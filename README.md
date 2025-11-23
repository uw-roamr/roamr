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

## Run App with Robot
- Open/build iOS app.
- Connect to bluetooth using the app
- Drive robot!
  
### Optional:
- Open HTML page in webpage folder.
- Run websocket on the websocket page of the app
- Connect to app websocket
- Drive robot!

## Localization Demo

See [WASM/README.md](WASM/README.md)
