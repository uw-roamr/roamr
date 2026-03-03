| Supported Targets | ESP32 | ESP32-C2 | ESP32-C3 | ESP32-C5 | ESP32-C6 | ESP32-C61 | ESP32-H2 | ESP32-H21 | ESP32-P4 | ESP32-S2 | ESP32-S3 |
| ----------------- | ----- | -------- | -------- | -------- | -------- | --------- | -------- | --------- | -------- | -------- | -------- |

# BLE Test Example

This folder structure was derived from the [esp-idf](https://github.com/espressif/esp-idf) 'blink' example.

This provides a demo which advertises the esp32 as "ESP32C6". You can download the nrfConnect app on your phone to connect to the device and upload data. Currently, the device only supports receiving and printing strings.

## How to Use Example

Before project configuration and build, be sure to set the correct chip target using `idf.py set-target <chip_name>`. If using vscode, you can also set the target in the bottom bar where you see a chip symbol.


### Hardware Required

* A development board with BLE compatibility (e.g. ESP32-C6-DevKitC etc.)
* A USB cable for Power supply and programming

See [Development Boards](https://www.espressif.com/en/products/devkits) for more information about it.

### Configure the Project

Open the project configuration menu (`idf.py menuconfig`). Or you can click the gear symbol in the bottom menu of vscode.

Make sure to select BLE 4.2 and disable BLE 5.

### Build and Flash

Run `idf.py -p PORT flash monitor` to build, flash and monitor the project. Or, you can click the wrench icon to build the project, then the lightning icon to flash the project.

(To exit the serial monitor, type ``Ctrl-]``.)

See the [Getting Started Guide](https://docs.espressif.com/projects/esp-idf/en/latest/get-started/index.html) for full steps to configure and use ESP-IDF to build projects.

### Monitor the Output

Run `idf.py monitor` to monitor the project. Or, you can the TV icon to monitor the serial output from the ESP32.


## SimpleFOC

SimpleFOC and SimpleFOC drivers are cloned into components.

Setup details (clone commands + required component `CMakeLists.txt` files):
[`SIMPLEFOC_COMPONENTS_SETUP.md`](SIMPLEFOC_COMPONENTS_SETUP.md)

# SimpleFOC Components Setup

This project expects `simplefoc` and `simplefoc_drivers` as local ESP-IDF components under `components/`.

## 1. Clone Repositories

From the project root:

```bash
mkdir -p components
git clone https://github.com/simplefoc/Arduino-FOC.git components/simplefoc
git clone https://github.com/simplefoc/Arduino-FOC-drivers.git components/simplefoc_drivers
```

Optional: pin to known-good revisions:

```bash
git -C components/simplefoc checkout 395b6cd4c621fe460c1d61a99bc0fc38913d5481
git -C components/simplefoc_drivers checkout ed05aa1644de36cbd19f43e8ea5c3edb643cefa9
```

## 2. Add `CMakeLists.txt` Files

Upstream repos do not include ESP-IDF component registration files, so create them.

### `components/simplefoc/CMakeLists.txt`

```cmake
file(GLOB_RECURSE SOURCES "src/*.cpp" "src/*.c")

idf_component_register(SRCS ${SOURCES}
                       INCLUDE_DIRS "src"
                       REQUIRES espressif__arduino-esp32)

target_compile_options(${COMPONENT_LIB} PRIVATE
                       -Wno-error=uninitialized
                       -Wno-error=overloaded-virtual
                       -Wno-error=switch
                       -Wno-error=comment)
```

### `components/simplefoc_drivers/CMakeLists.txt`

```cmake
file(GLOB_RECURSE SOURCES "src/*.cpp" "src/*.c")

idf_component_register(SRCS ${SOURCES}
                       INCLUDE_DIRS "src"
                       REQUIRES espressif__arduino-esp32 simplefoc)

target_compile_options(${COMPONENT_LIB} PRIVATE
                       -Wno-error=overloaded-virtual
                       -Wno-error=switch
                       -Wno-error=comment)
```

## 3. Confirm Main Component Dependencies

Ensure [`main/CMakeLists.txt`](main/CMakeLists.txt) includes:

- `REQUIRES ... simplefoc ... simplefoc_drivers`

Then build:

```bash
idf.py build
```

## BLE Odometry Upload Protocol

The firmware now exposes one custom service (`0x00FF`) with 3 characteristics:

- `0xFF01` control (`WRITE`, `WRITE_NO_RSP`)
- `0xFF02` data (`NOTIFY`)
- `0xFF03` status (`READ`)

### Control commands (`FF01`)

- `START <duration_ms> [sample_period_ms]`
- `STOP`
- `CLEAR`
- `GET_STATUS`

Legacy motor command writes (`"<left> <right> <duration>"`) still work on `FF01`.

### Data frames (`FF02` notify)

Each notification is MTU-aware and chunked (`max_payload = ATT_MTU - 3`).

- Header:
- `seq`: `uint16` little-endian
- `n`: `uint8` sample count
- Payload:
- `n` samples, each sample:
- `dl_ticks`: `int16` little-endian
- `dr_ticks`: `int16` little-endian

So frame size is `3 + 4*n` bytes.

### Status payload (`FF03` read, little-endian)

- `state`: `uint8` (`0=IDLE, 1=RECORDING, 2=UPLOADING`)
- `buffered_samples`: `uint16`
- `dropped_samples`: `uint16`
- `last_seq`: `uint16` (`0xFFFF` before first upload frame)
- `sample_period_ms`: `uint16`

### docker build

For reproducible builds across platforms, we suggest using the docker container for release-v5.5

https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/tools/idf-docker-image.html

```sh
docker run --rm -v $PWD:/project -w /project -u $UID -e HOME=/tmp -it espressif/idf:release-v5.5
```

## Linux
```sh
docker run --rm -v $PWD:/project -w /project -u $UID -e HOME=/tmp -it --device=/dev/ttyUSB0 --group-add dialout espressif/idf:release-v5.5
```

Build, then flash the firmware.

```sh
idf.py build
```

Then flash the ESP. It may be necessary to configure additional settings in Windows or MacOS.

```sh
idf.py flash
```

## Windows Instructions:

Run the following command in a separate terminal to open the COM port to the ESP (check your COM port in device manager)
```sh
esp_rfc2217_server -v -p 4000 COM3
```
To flash the ESP,  run the following command in roamr/embedded/ble-test
```sh
MSYS_NO_PATHCONV=1 docker run --rm -v "/$(pwd):/project" -w /project -u $UID -e HOME=/tmp -it espressif/idf:release-v5.5 idf.py --port 'rfc2217://host.docker.internal:4000?ign_set_control' flash
```
