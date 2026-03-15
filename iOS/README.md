# iOS App

## Getting started

1. [Enable developer mode on iPhone](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

2. Under the `Signing & Capabilities` tab in XCode, select a team (e.g. Personal Team) and enter a unique identifier.

3. Click Build.

Core components:

## ExecuTorch

The dynamic model bridge in `Managers/ModelRunner.swift` is written to use the
official ExecuTorch Swift package when it is linked into the app. Until that
package is added in Xcode, `ml_open_model` will return `runtime_unavailable`.

## How build new WAMR
- Clone WAMR (https://github.com/bytecodealliance/wasm-micro-runtime)
- Navigate to `/wasm-micro-runtime/product-mini/platforms`
- Run `generate_xcodeproj.sh`
- Open the XCode project and edit the `CMakeList.txt` file to be the same as the one provided in our repo.
- Run the `ALL_BUILD` target
- Open the header files, located at `/wasm-micro-runtime/product-mini/platforms/ios/iwasm-proj/distribution/wasm`
- Copy them to your project and include them in a header bridging file
- Copy the library (.a file) to your project, located at `/wasm-micro-runtime/product-mini/platforms/ios/iwasm-proj`
- Check this `library.a` file is added to `Link Binaries with Libraries` inside `Build Phases`
- Add the folder `library.a` lives in to `Library Search Paths` inside `Build Settings`

## WebAssembly Runner

- [WAMR: WebAssemby Micro Runtime](https://bytecodealliance.github.io/wamr.dev/)

## Sensor Access

- Managers/LiDARManager.swift

## TODO:

- Protobuf serialization/deserialization
- Connect sensors to WASM

- manage different PRODUCT_BUNDLE_IDENTIFIER under project.pbxproj
