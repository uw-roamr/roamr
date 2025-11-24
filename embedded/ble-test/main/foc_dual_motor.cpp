#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"

#include "esp_log.h"
#include <stdarg.h>
#include <stdio.h>

extern "C" void __wrap_esp_log_write(esp_log_level_t level, const char *tag,
                                     const char *format, ...) {
  va_list args;
  va_start(args, format);
  // Simple redirection to vprintf
  // You might want to format it better if needed, e.g. adding level/tag
  // printf("[%s] ", tag);
  vprintf(format, args);
  va_end(args);
}

#include "encoders/as5048a/MagneticSensorAS5048A.h"
#include <Arduino.h>
#include <SPI.h>
#include <SimpleFOC.h>
#include <SimpleFOCDrivers.h>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_log.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define GATTS_TAG "BLE_DEMO"
#define DEVICE_NAME "ESP32_C6"
#define GATTS_SERVICE_UUID 0x00FF
#define GATTS_CHAR_UUID 0xFF01
#define GATTS_NUM_HANDLE 4

constexpr int PIN_MOSI = 4;
constexpr int PIN_SCLK = 5;
constexpr int PIN_MISO = 6;
constexpr int PIN_CS1 = 7;
constexpr int PIN_CS2 = 15;

constexpr int PIN_DRIVER2_1 = 0;
constexpr int PIN_DRIVER2_2 = 1;
constexpr int PIN_DRIVER2_3 = 8;
constexpr int PIN_DRIVER2_EN = 10;

constexpr int PIN_DRIVER1_1 = 23;
constexpr int PIN_DRIVER1_2 = 22;
constexpr int PIN_DRIVER1_3 = 21;
constexpr int PIN_DRIVER1_EN = 20;

MagneticSensorAS5048A sensor1(PIN_CS1);
MagneticSensorAS5048A sensor2(PIN_CS2);

BLDCDriver3PWM driver1(PIN_DRIVER1_1, PIN_DRIVER1_2, PIN_DRIVER1_3,
                       PIN_DRIVER1_EN);
BLDCDriver3PWM driver2(PIN_DRIVER2_1, PIN_DRIVER2_2, PIN_DRIVER2_3,
                       PIN_DRIVER2_EN);
BLDCMotor motor1(7);
BLDCMotor motor2(7);
Commander command = Commander(Serial);

void doMotor1(char *cmd) { command.motor(&motor1, cmd); }
void doMotor2(char *cmd) { command.motor(&motor2, cmd); }

static uint8_t raw_adv_data[] = {0x02, 0x01, 0x06, 0x09, 0x09, 'E', 'S',
                                 'P',  '3',  '2',  '_',  'C',  '6'};

static esp_ble_adv_params_t adv_params = {
    .adv_int_min = 0x20,
    .adv_int_max = 0x40,
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static uint16_t gatts_handle_table[GATTS_NUM_HANDLE];

static void gatts_event_handler(esp_gatts_cb_event_t event,
                                esp_gatt_if_t gatts_if,
                                esp_ble_gatts_cb_param_t *param) {
  switch (event) {
  case ESP_GATTS_REG_EVT: {
    ESP_LOGI(GATTS_TAG, "GATT server registered");

    esp_ble_gap_set_device_name(DEVICE_NAME);
    esp_ble_gap_config_adv_data_raw(raw_adv_data, sizeof(raw_adv_data));

    esp_gatt_srvc_id_t service_id;
    service_id.is_primary = true;
    service_id.id.inst_id = 0;
    service_id.id.uuid.len = ESP_UUID_LEN_16;
    service_id.id.uuid.uuid.uuid16 = GATTS_SERVICE_UUID;

    esp_ble_gatts_create_service(gatts_if, &service_id, GATTS_NUM_HANDLE);
    break;
  }

  case ESP_GATTS_CREATE_EVT: {
    ESP_LOGI(GATTS_TAG, "Service created");
    gatts_handle_table[0] = param->create.service_handle;
    esp_ble_gatts_start_service(gatts_handle_table[0]);

    esp_bt_uuid_t char_uuid;
    char_uuid.len = ESP_UUID_LEN_16;
    char_uuid.uuid.uuid16 = GATTS_CHAR_UUID;

    esp_ble_gatts_add_char(gatts_handle_table[0], &char_uuid,
                           ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
                           ESP_GATT_CHAR_PROP_BIT_READ |
                               ESP_GATT_CHAR_PROP_BIT_WRITE |
                               ESP_GATT_CHAR_PROP_BIT_WRITE_NR,
                           NULL, NULL);
    break;
  }

  case ESP_GATTS_ADD_CHAR_EVT:
    ESP_LOGI(GATTS_TAG, "Characteristic added, handle: %d",
             param->add_char.attr_handle);
    gatts_handle_table[1] = param->add_char.attr_handle;
    break;

  case ESP_GATTS_CONNECT_EVT:
    ESP_LOGI(GATTS_TAG, "Device connected");
    break;

  case ESP_GATTS_DISCONNECT_EVT:
    ESP_LOGI(GATTS_TAG, "Device disconnected");
    esp_ble_gap_start_advertising(&adv_params);
    break;

  case ESP_GATTS_WRITE_EVT:
    if (param->write.need_rsp) {
      ESP_LOGI(GATTS_TAG, "Received message WITH response: %.*s",
               param->write.len, param->write.value);

      esp_gatt_rsp_t rsp;
      memset(&rsp, 0, sizeof(esp_gatt_rsp_t));
      rsp.attr_value.handle = param->write.handle;
      rsp.attr_value.len = param->write.len;
      memcpy(rsp.attr_value.value, param->write.value, param->write.len);

      esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                  param->write.trans_id, ESP_GATT_OK, &rsp);
      ESP_LOGI(GATTS_TAG, "Response sent");
    } else {
      ESP_LOGI(GATTS_TAG, "Received message WITHOUT response: %.*s",
               param->write.len, param->write.value);
    }
    // Handle SimpleFOC command
    if (param->write.len > 0) {
      // Use a fixed buffer or std::string to avoid VLA
      char cmd[128];
      int len = param->write.len;
      if (len > 127)
        len = 127;

      memcpy(cmd, param->write.value, len);
      cmd[len] = '\0';

      // Parse "left right duration"
      // Example: "50 -50 100"
      int left_pct, right_pct, duration_ms;
      if (sscanf(cmd, "%d %d %d", &left_pct, &right_pct, &duration_ms) == 3) {
        // Map percentage (-100 to 100) to voltage (-12 to 12)
        // Assuming 12V power supply as set in setup()
        float left_voltage = (left_pct / 100.0f) * 12.0f;
        float right_voltage = (right_pct / 100.0f) * 12.0f;

        motor1.target = left_voltage;
        motor2.target = right_voltage;

        // TODO: Implement duration/watchdog logic
        // For now, we just set the target. The duration suggests we should
        // stop after X ms. Since this is an event handler, we can't block. We
        // should update a timestamp and check it in the loop() or a separate
        // task. For simplicity in this step, we'll just set the target. Real
        // implementation would need a global "last_command_time" and
        // "command_duration".

        ESP_LOGI(GATTS_TAG, "Motor Target: L=%.2fV, R=%.2fV", left_voltage,
                 right_voltage);
      } else {
        // Fallback to Commander for other commands (e.g. "A10")
        command.run(cmd);
      }
    }
    break;

  default:
    break;
  }
}

static void gap_event_handler(esp_gap_ble_cb_event_t event,
                              esp_ble_gap_cb_param_t *param) {
  switch (event) {
  case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
    ESP_LOGI(GATTS_TAG, "Raw advertising data set, starting advertising");
    esp_ble_gap_start_advertising(&adv_params);
    break;
  case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
    if (param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS) {
      ESP_LOGI(GATTS_TAG, "Advertising started successfully");
    } else {
      ESP_LOGE(GATTS_TAG, "Advertising start failed: %d",
               param->adv_start_cmpl.status);
    }
    break;
  default:
    break;
  }
}

void setup() {
  Serial.begin(115200);

  // BLE Setup
  esp_err_t ret = nvs_flash_init();
  if (ret == ESP_ERR_NVS_NO_FREE_PAGES ||
      ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    ret = nvs_flash_init();
  }
  ESP_ERROR_CHECK(ret);

  ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));

  esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
  ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
  ESP_ERROR_CHECK(esp_bluedroid_init());
  ESP_ERROR_CHECK(esp_bluedroid_enable());

  esp_ble_gatts_register_callback(gatts_event_handler);
  esp_ble_gap_register_callback(gap_event_handler);
  esp_ble_gatts_app_register(0);

  // SimpleFOC Setup
  SPI.begin(PIN_SCLK, PIN_MISO, PIN_MOSI);

  sensor1.init();
  sensor2.init();
  motor1.linkSensor(&sensor1);
  motor2.linkSensor(&sensor2);

  driver1.voltage_power_supply = 12;
  driver2.voltage_power_supply = 12;
  driver1.voltage_limit = 12;
  driver2.voltage_limit = 12;
  if (!driver1.init()) {
    Serial.println("Driver 1 failed");
    return;
  }
  if (!driver2.init()) {
    Serial.println("Driver 2 failed");
    return;
  }
  motor1.linkDriver(&driver1);
  motor2.linkDriver(&driver2);

  motor1.torque_controller = TorqueControlType::voltage;
  motor2.torque_controller = TorqueControlType::voltage;
  motor1.controller = MotionControlType::torque;
  motor2.controller = MotionControlType::torque;

  motor1.voltage_sensor_align = 12.0f;
  motor2.voltage_sensor_align = 12.0f;
  motor1.useMonitoring(Serial);
  motor2.useMonitoring(Serial);

  if (!motor1.init()) {
    Serial.println("Motor 1 failed");
    return;
  }
  if (!motor2.init()) {
    Serial.println("Motor 2 failed");
    return;
  }

  if (!motor1.initFOC()) {
    Serial.println("FOC 1 failed");
    return;
  }
  if (!motor2.initFOC()) {
    Serial.println("FOC 2 failed");
    return;
  }

  motor1.target = 0.0; // Nm
  motor2.target = 0.0; // Nm

  command.add('A', doMotor1, "Motor1");
  command.add('B', doMotor2, "Motor2");
  Serial.println(F("Motor ready."));
  Serial.println(F("Set the target with command A or B:"));
}

void loop() {
  motor1.loopFOC();
  motor2.loopFOC();
  motor1.move();
  motor2.move();
  command.run();

  static uint32_t last_print = 0;
  if (millis() - last_print > 1000) {
    last_print = millis();
    Serial.printf("M1: Target=%.2f V, Vel=%.2f | M2: Target=%.2f V, Vel=%.2f\n",
                  motor1.target, motor1.shaft_velocity, motor2.target,
                  motor2.shaft_velocity);
  }
}

extern "C" void app_main() {
  initArduino();
  setup();
  while (true) {
    loop();
  }
}
