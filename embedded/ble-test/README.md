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