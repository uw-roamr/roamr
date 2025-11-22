# iOS App

Core components:

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

- WasmInterpreter: Swift wrapper around Wasm3
  - WasmType.swift: datatypes (float32, float64, int32, int64)

## Sensor Access

- Managers/LiDARManager.swift


## TODO:

- Protobuf serialization/deserialization
- Connect sensors to WASM

- manage different PRODUCT_BUNDLE_IDENTIFIER under project.pbxproj