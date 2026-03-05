#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"

#include "encoders/as5048a/MagneticSensorAS5048A.h"
#include "drivers/drv8316/drv8316.h"
#include <Arduino.h>
#include <SPI.h>
#include <SimpleFOC.h>
#include <SimpleFOCDrivers.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatt_common_api.h"
#include "esp_gatts_api.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#define DEVICE_NAME "ESP32_C6"
#define GATTS_SERVICE_UUID 0x00FF
#define GATTS_CONTROL_CHAR_UUID 0xFF01
#define GATTS_DATA_CHAR_UUID 0xFF02
#define GATTS_NUM_HANDLE 8

constexpr uint16_t BLE_DEFAULT_ATT_MTU = 23;
constexpr uint16_t BLE_PREFERRED_ATT_MTU = 185;
constexpr size_t BLE_DATA_CHAR_MAX_LEN = 244;

constexpr size_t ODOM_RING_CAPACITY = 2048;
constexpr uint16_t ODOM_DEFAULT_SAMPLE_PERIOD_MS = 20;
constexpr uint16_t ODOM_MIN_SAMPLE_PERIOD_MS = 5;
constexpr uint16_t ODOM_MAX_SAMPLE_PERIOD_MS = 1000;
constexpr int kLeftEncoderSign = 1;
constexpr int kRightEncoderSign = -1;
constexpr uint8_t ODOM_FRAME_HEADER_SIZE = 3; // seq:uint16 + n:uint8
constexpr uint8_t ODOM_SAMPLE_SIZE = 4;       // dl:int16 + dr:int16
constexpr uint8_t MAX_NOTIFY_FRAMES_PER_LOOP = 4;
constexpr size_t CONTROL_CMD_MAX_LEN = 127;

// constexpr int PIN_MOSI = 4;
// constexpr int PIN_SCLK = 5;
// constexpr int PIN_MISO = 6;
// constexpr int PIN_CS1 = 7;
// constexpr int PIN_CS2 = 15;
constexpr int PIN_MOSI = 11;
constexpr int PIN_SCLK = 12;
constexpr int PIN_MISO = 13;
constexpr int PIN_CS1 = 17;
constexpr int PIN_CS2 = 18;

// constexpr int PIN_DRIVER1_1 = 0;
// constexpr int PIN_DRIVER1_2 = 1;
// constexpr int PIN_DRIVER1_3 = 8;
// constexpr int PIN_DRIVER1_EN = 10;
constexpr int PIN_DRIVER1_1 = 41;
constexpr int PIN_DRIVER1_2 = 42;
constexpr int PIN_DRIVER1_3 = 45;
constexpr int PIN_DRIVER1_CS = 47;

// constexpr int PIN_DRIVER2_1 = 23;
// constexpr int PIN_DRIVER2_2 = 22;
// constexpr int PIN_DRIVER2_3 = 21;
// constexpr int PIN_DRIVER2_EN = 20;
constexpr int PIN_DRIVER2_1 = 38;
constexpr int PIN_DRIVER2_2 = 39;
constexpr int PIN_DRIVER2_3 = 40;
constexpr int PIN_DRIVER2_CS = 48;

struct OdomSample {
  int16_t dl_ticks;
  int16_t dr_ticks;
};

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

SPISettings g_spi_settings(1000000, MSBFIRST, SPI_MODE1);
MagneticSensorAS5048A g_sensor_left(PIN_CS1, false, g_spi_settings);
MagneticSensorAS5048A g_sensor_right(PIN_CS2, false, g_spi_settings);

DRV8316Driver3PWM g_driver_left(PIN_DRIVER1_1, PIN_DRIVER1_2, PIN_DRIVER1_3,
                                PIN_DRIVER1_CS);
DRV8316Driver3PWM g_driver_right(PIN_DRIVER2_1, PIN_DRIVER2_2, PIN_DRIVER2_3,
                                 PIN_DRIVER2_CS);
BLDCMotor g_motor_left(7);
BLDCMotor g_motor_right(7);

static uint16_t g_service_handle = 0;
static uint16_t g_control_char_handle = 0;
static uint16_t g_data_char_handle = 0;
static uint16_t g_data_cccd_handle = 0;

static esp_gatt_if_t g_gatts_if = ESP_GATT_IF_NONE;
static uint16_t g_conn_id = 0;
static bool g_ble_connected = false;
static bool g_data_notify_enabled = false;
static uint16_t g_att_mtu = BLE_DEFAULT_ATT_MTU;

static OdomSample g_ring_buffer[ODOM_RING_CAPACITY];
static size_t g_ring_head = 0;
static size_t g_ring_tail = 0;
static size_t g_ring_count = 0;

static uint16_t g_frame_seq = 0;
static uint16_t g_sample_period_ms = ODOM_DEFAULT_SAMPLE_PERIOD_MS;
static uint32_t g_last_sample_ms = 0;
static bool g_prev_raw_valid = false;
static uint16_t g_prev_left_raw = 0;
static uint16_t g_prev_right_raw = 0;

static uint8_t g_control_char_value[CONTROL_CMD_MAX_LEN + 1] = {0};
static uint8_t g_data_char_value[BLE_DATA_CHAR_MAX_LEN] = {0};
static uint8_t g_data_cccd_value[2] = {0, 0};

static bool g_motor_left_ready = false;
static bool g_motor_right_ready = false;
static const char *kDiagTag = "BOOT_DIAG";

static void logHeapAndStack(const char *stage) {
  const size_t free_heap = heap_caps_get_free_size(MALLOC_CAP_8BIT);
  const size_t min_free_heap = heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT);
  const size_t largest_block = heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
  const UBaseType_t stack_hw = uxTaskGetStackHighWaterMark(nullptr);
  ESP_LOGI(kDiagTag,
           "%s free=%u min_free=%u largest=%u stack_hw_words=%u",
           stage, static_cast<unsigned>(free_heap), static_cast<unsigned>(min_free_heap),
           static_cast<unsigned>(largest_block), static_cast<unsigned>(stack_hw));
}

static int clampPercent(int value) {
  if (value < -100) {
    return -100;
  }
  if (value > 100) {
    return 100;
  }
  return value;
}

static uint16_t clampSamplePeriodMs(int requested_ms) {
  if (requested_ms < static_cast<int>(ODOM_MIN_SAMPLE_PERIOD_MS)) {
    return ODOM_MIN_SAMPLE_PERIOD_MS;
  }
  if (requested_ms > static_cast<int>(ODOM_MAX_SAMPLE_PERIOD_MS)) {
    return ODOM_MAX_SAMPLE_PERIOD_MS;
  }
  return static_cast<uint16_t>(requested_ms);
}

static int parseIntTokens(const char *text, int *out_values, int max_values) {
  if (text == nullptr || out_values == nullptr || max_values <= 0) {
    return 0;
  }

  const char *p = text;
  int count = 0;
  while (*p != '\0' && count < max_values) {
    while (*p != '\0' && isspace(static_cast<unsigned char>(*p))) {
      p++;
    }
    if (*p == '\0') {
      break;
    }

    char *end = nullptr;
    long value = strtol(p, &end, 10);
    if (end == p) {
      break;
    }

    out_values[count++] = static_cast<int>(value);
    p = end;
  }

  return count;
}

static void odomBufferClear() {
  g_ring_head = 0;
  g_ring_tail = 0;
  g_ring_count = 0;
  g_frame_seq = 0;
}

static void odomBufferPush(const OdomSample &sample) {
  if (g_ring_count >= ODOM_RING_CAPACITY) {
    g_ring_tail = (g_ring_tail + 1) % ODOM_RING_CAPACITY;
    g_ring_count--;
  }

  g_ring_buffer[g_ring_head] = sample;
  g_ring_head = (g_ring_head + 1) % ODOM_RING_CAPACITY;
  g_ring_count++;
}

static OdomSample odomBufferPeek(size_t index) {
  return g_ring_buffer[(g_ring_tail + index) % ODOM_RING_CAPACITY];
}

static void odomBufferDrop(size_t count) {
  if (count > g_ring_count) {
    count = g_ring_count;
  }
  g_ring_tail = (g_ring_tail + count) % ODOM_RING_CAPACITY;
  g_ring_count -= count;
}

static int16_t wrappedDeltaTicks(uint16_t current, uint16_t previous) {
  int32_t delta = static_cast<int32_t>(current) - static_cast<int32_t>(previous);
  constexpr int32_t kHalfTurnTicks = AS5048A_CPR / 2;

  if (delta > kHalfTurnTicks) {
    delta -= AS5048A_CPR;
  } else if (delta < -kHalfTurnTicks) {
    delta += AS5048A_CPR;
  }

  return static_cast<int16_t>(delta);
}

static void setMotorTargetsPercent(int left_pct, int right_pct) {
  const float left_voltage = (clampPercent(left_pct) / 100.0f) * 12.0f;
  const float right_voltage = -(clampPercent(right_pct) / 100.0f) * 12.0f;
  g_motor_left.target = left_voltage;
  g_motor_right.target = right_voltage;
}

static void handleControlCommand(const uint8_t *data, uint16_t len) {
  if (data == nullptr || len == 0) {
    return;
  }

  char cmd[CONTROL_CMD_MAX_LEN + 1];
  size_t copy_len = len;
  if (copy_len > CONTROL_CMD_MAX_LEN) {
    copy_len = CONTROL_CMD_MAX_LEN;
  }
  memcpy(cmd, data, copy_len);
  cmd[copy_len] = '\0';

  while (copy_len > 0 && isspace(static_cast<unsigned char>(cmd[copy_len - 1]))) {
    cmd[copy_len - 1] = '\0';
    copy_len--;
  }

  if (strncmp(cmd, "SET_PERIOD", 10) == 0) {
    int values[1] = {static_cast<int>(ODOM_DEFAULT_SAMPLE_PERIOD_MS)};
    if (parseIntTokens(cmd + 10, values, 1) >= 1) {
      g_sample_period_ms = clampSamplePeriodMs(values[0]);
    }
    return;
  }

  if (strcmp(cmd, "CLEAR") == 0) {
    odomBufferClear();
    return;
  }

  int values[3] = {0, 0, 0};
  if (parseIntTokens(cmd, values, 3) == 3) {
    setMotorTargetsPercent(values[0], values[1]);
  }
}

static void addControlCharacteristic() {
  esp_bt_uuid_t char_uuid = {};
  char_uuid.len = ESP_UUID_LEN_16;
  char_uuid.uuid.uuid16 = GATTS_CONTROL_CHAR_UUID;

  esp_attr_value_t control_attr = {};
  control_attr.attr_max_len = sizeof(g_control_char_value);
  control_attr.attr_len = 1;
  control_attr.attr_value = g_control_char_value;

  esp_ble_gatts_add_char(g_service_handle, &char_uuid, ESP_GATT_PERM_WRITE,
                         ESP_GATT_CHAR_PROP_BIT_WRITE |
                             ESP_GATT_CHAR_PROP_BIT_WRITE_NR,
                         &control_attr, nullptr);
}

static void addDataCharacteristic() {
  esp_bt_uuid_t char_uuid = {};
  char_uuid.len = ESP_UUID_LEN_16;
  char_uuid.uuid.uuid16 = GATTS_DATA_CHAR_UUID;

  esp_attr_value_t data_attr = {};
  data_attr.attr_max_len = sizeof(g_data_char_value);
  data_attr.attr_len = 1;
  data_attr.attr_value = g_data_char_value;

  esp_ble_gatts_add_char(g_service_handle, &char_uuid, ESP_GATT_PERM_READ,
                         ESP_GATT_CHAR_PROP_BIT_NOTIFY, &data_attr, nullptr);
}

static void addDataCccdDescriptor() {
  esp_bt_uuid_t descr_uuid = {};
  descr_uuid.len = ESP_UUID_LEN_16;
  descr_uuid.uuid.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;

  esp_attr_value_t cccd_attr = {};
  cccd_attr.attr_max_len = sizeof(g_data_cccd_value);
  cccd_attr.attr_len = sizeof(g_data_cccd_value);
  cccd_attr.attr_value = g_data_cccd_value;

  esp_ble_gatts_add_char_descr(g_service_handle, &descr_uuid,
                               ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
                               &cccd_attr, nullptr);
}

static void sendWriteResponseIfNeeded(esp_gatt_if_t gatts_if,
                                      esp_ble_gatts_cb_param_t *param) {
  if (!param->write.need_rsp) {
    return;
  }

  esp_gatt_rsp_t rsp = {};
  rsp.attr_value.handle = param->write.handle;
  rsp.attr_value.offset = param->write.offset;
  rsp.attr_value.auth_req = ESP_GATT_AUTH_REQ_NONE;

  uint16_t copy_len = param->write.len;
  if (copy_len > sizeof(rsp.attr_value.value)) {
    copy_len = sizeof(rsp.attr_value.value);
  }
  rsp.attr_value.len = copy_len;
  memcpy(rsp.attr_value.value, param->write.value, copy_len);

  esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                              param->write.trans_id, ESP_GATT_OK, &rsp);
}

static void odometryUpdateTick() {
  const uint32_t now = millis();

  if (!g_prev_raw_valid) {
    g_prev_left_raw = g_sensor_left.readRawAngle();
    g_prev_right_raw = g_sensor_right.readRawAngle();
    g_prev_raw_valid = true;
    g_last_sample_ms = now;
    return;
  }

  if (static_cast<uint32_t>(now - g_last_sample_ms) < g_sample_period_ms) {
    return;
  }

  const uint16_t left_raw = g_sensor_left.readRawAngle();
  const uint16_t right_raw = g_sensor_right.readRawAngle();

  const int16_t dl = wrappedDeltaTicks(left_raw, g_prev_left_raw);
  const int16_t dr = wrappedDeltaTicks(right_raw, g_prev_right_raw);
  OdomSample sample = {};
  sample.dl_ticks = static_cast<int16_t>(kLeftEncoderSign * static_cast<int32_t>(dl));
  sample.dr_ticks = static_cast<int16_t>(kRightEncoderSign * static_cast<int32_t>(dr));
  odomBufferPush(sample);

  g_prev_left_raw = left_raw;
  g_prev_right_raw = right_raw;
  g_last_sample_ms = now;
}

static void bleUploadLoop() {
  if (!g_ble_connected || !g_data_notify_enabled || g_ring_count == 0 ||
      g_data_char_handle == 0 || g_gatts_if == ESP_GATT_IF_NONE) {
    return;
  }

  size_t max_payload = BLE_DATA_CHAR_MAX_LEN;
  if (g_att_mtu > 3) {
    const size_t mtu_payload = static_cast<size_t>(g_att_mtu - 3);
    if (mtu_payload < max_payload) {
      max_payload = mtu_payload;
    }
  }

  if (max_payload <= ODOM_FRAME_HEADER_SIZE) {
    return;
  }

  size_t max_samples = (max_payload - ODOM_FRAME_HEADER_SIZE) / ODOM_SAMPLE_SIZE;
  if (max_samples == 0) {
    return;
  }
  if (max_samples > 255) {
    max_samples = 255;
  }

  uint8_t frame[BLE_DATA_CHAR_MAX_LEN];

  for (uint8_t i = 0; i < MAX_NOTIFY_FRAMES_PER_LOOP; i++) {
    if (g_ring_count == 0) {
      break;
    }

    size_t samples_in_frame = g_ring_count < max_samples ? g_ring_count : max_samples;
    if (samples_in_frame == 0) {
      break;
    }

    frame[0] = static_cast<uint8_t>(g_frame_seq & 0xFF);
    frame[1] = static_cast<uint8_t>((g_frame_seq >> 8) & 0xFF);
    frame[2] = static_cast<uint8_t>(samples_in_frame);

    size_t offset = ODOM_FRAME_HEADER_SIZE;
    for (size_t sample_index = 0; sample_index < samples_in_frame; sample_index++) {
      const OdomSample sample = odomBufferPeek(sample_index);
      const uint16_t dl = static_cast<uint16_t>(sample.dl_ticks);
      const uint16_t dr = static_cast<uint16_t>(sample.dr_ticks);

      frame[offset++] = static_cast<uint8_t>(dl & 0xFF);
      frame[offset++] = static_cast<uint8_t>((dl >> 8) & 0xFF);
      frame[offset++] = static_cast<uint8_t>(dr & 0xFF);
      frame[offset++] = static_cast<uint8_t>((dr >> 8) & 0xFF);
    }

    const esp_err_t err = esp_ble_gatts_send_indicate(
        g_gatts_if, g_conn_id, g_data_char_handle, offset, frame, false);
    if (err != ESP_OK) {
      break;
    }

    odomBufferDrop(samples_in_frame);
    g_frame_seq++;
  }
}

static void gattsEventHandler(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if,
                              esp_ble_gatts_cb_param_t *param) {
  switch (event) {
  case ESP_GATTS_REG_EVT: {
    g_gatts_if = gatts_if;

    esp_ble_gap_set_device_name(DEVICE_NAME);
    esp_ble_gap_config_adv_data_raw(raw_adv_data, sizeof(raw_adv_data));
    esp_ble_gatt_set_local_mtu(BLE_PREFERRED_ATT_MTU);

    esp_gatt_srvc_id_t service_id = {};
    service_id.is_primary = true;
    service_id.id.inst_id = 0;
    service_id.id.uuid.len = ESP_UUID_LEN_16;
    service_id.id.uuid.uuid.uuid16 = GATTS_SERVICE_UUID;

    esp_ble_gatts_create_service(gatts_if, &service_id, GATTS_NUM_HANDLE);
    break;
  }

  case ESP_GATTS_CREATE_EVT: {
    if (param->create.status != ESP_GATT_OK) {
      break;
    }

    g_service_handle = param->create.service_handle;
    esp_ble_gatts_start_service(g_service_handle);
    addControlCharacteristic();
    break;
  }

  case ESP_GATTS_ADD_CHAR_EVT: {
    if (param->add_char.status != ESP_GATT_OK) {
      break;
    }

    const uint16_t uuid = param->add_char.char_uuid.uuid.uuid16;
    if (uuid == GATTS_CONTROL_CHAR_UUID) {
      g_control_char_handle = param->add_char.attr_handle;
      addDataCharacteristic();
    } else if (uuid == GATTS_DATA_CHAR_UUID) {
      g_data_char_handle = param->add_char.attr_handle;
      addDataCccdDescriptor();
    }
    break;
  }

  case ESP_GATTS_ADD_CHAR_DESCR_EVT:
    if (param->add_char_descr.status == ESP_GATT_OK &&
        param->add_char_descr.descr_uuid.uuid.uuid16 ==
            ESP_GATT_UUID_CHAR_CLIENT_CONFIG) {
      g_data_cccd_handle = param->add_char_descr.attr_handle;
    }
    break;

  case ESP_GATTS_CONNECT_EVT:
    g_ble_connected = true;
    g_conn_id = param->connect.conn_id;
    g_gatts_if = gatts_if;
    g_data_notify_enabled = false;
    g_att_mtu = BLE_DEFAULT_ATT_MTU;
    odomBufferClear();
    g_prev_raw_valid = false;
    break;

  case ESP_GATTS_DISCONNECT_EVT:
    g_ble_connected = false;
    g_data_notify_enabled = false;
    g_att_mtu = BLE_DEFAULT_ATT_MTU;
    odomBufferClear();
    g_prev_raw_valid = false;
    esp_ble_gap_start_advertising(&adv_params);
    break;

  case ESP_GATTS_MTU_EVT:
    g_att_mtu = param->mtu.mtu;
    break;

  case ESP_GATTS_WRITE_EVT: {
    if (param->write.handle == g_data_cccd_handle && param->write.len >= 2) {
      const uint16_t cccd = static_cast<uint16_t>(param->write.value[0]) |
                            (static_cast<uint16_t>(param->write.value[1]) << 8);
      g_data_notify_enabled = (cccd & 0x0001u) != 0;
    } else if (param->write.handle == g_control_char_handle) {
      handleControlCommand(param->write.value, param->write.len);
    }

    sendWriteResponseIfNeeded(gatts_if, param);
    break;
  }

  default:
    break;
  }
}

static void gapEventHandler(esp_gap_ble_cb_event_t event,
                            esp_ble_gap_cb_param_t *param) {
  switch (event) {
  case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
    esp_ble_gap_start_advertising(&adv_params);
    break;
  case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
    (void)param;
    break;
  default:
    break;
  }
}

static void setupMotors() {
  pinMode(PIN_CS1, OUTPUT);
  digitalWrite(PIN_CS1, HIGH);
  pinMode(PIN_CS2, OUTPUT);
  digitalWrite(PIN_CS2, HIGH);
  pinMode(PIN_DRIVER1_CS, OUTPUT);
  digitalWrite(PIN_DRIVER1_CS, HIGH);
  pinMode(PIN_DRIVER2_CS, OUTPUT);
  digitalWrite(PIN_DRIVER2_CS, HIGH);


  g_sensor_left.init();
  g_sensor_right.init();
  g_motor_left.linkSensor(&g_sensor_left);
  g_motor_right.linkSensor(&g_sensor_right);

  g_driver_left.voltage_power_supply = 12;
  g_driver_right.voltage_power_supply = 12;
  g_driver_left.voltage_limit = 12;
  g_driver_right.voltage_limit = 12;

  g_driver_left.init(&SPI);
  g_driver_right.init(&SPI);

  SPI.begin(PIN_SCLK, PIN_MISO, PIN_MOSI);
  gpio_pullup_en((gpio_num_t)PIN_MISO);

  g_driver_left.setSDOMode(DRV8316_SDOMode::SDOMode_PushPull);
  g_driver_right.setSDOMode(DRV8316_SDOMode::SDOMode_PushPull);

  g_driver_left.setBuckPowerSequencingEnabled(false);
  g_driver_right.setBuckPowerSequencingEnabled(false);

  g_motor_left.linkDriver(&g_driver_left);
  g_motor_right.linkDriver(&g_driver_right);

  g_motor_left.torque_controller = TorqueControlType::voltage;
  g_motor_right.torque_controller = TorqueControlType::voltage;
  g_motor_left.controller = MotionControlType::torque;
  g_motor_right.controller = MotionControlType::torque;

  g_motor_left.voltage_sensor_align = 12.0f;
  g_motor_right.voltage_sensor_align = 12.0f;

  bool left_ready = g_motor_left.init();
  bool right_ready = g_motor_right.init();

  if (left_ready) {
    left_ready = g_motor_left.initFOC();
  }

  if (right_ready) {
    right_ready = g_motor_right.initFOC();
  }

  g_motor_left.target = 0.0f;
  g_motor_right.target = 0.0f;

  g_motor_left_ready = left_ready;
  g_motor_right_ready = right_ready;
}

static void initBleStack() {
  logHeapAndStack("ble:init:start");

  esp_err_t ret = nvs_flash_init();
  if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    ret = nvs_flash_init();
  }
  ESP_ERROR_CHECK(ret);
  logHeapAndStack("ble:init:after_nvs");

  if (!heap_caps_check_integrity_all(true)) {
    ESP_LOGE(kDiagTag, "Heap integrity check failed before BT init");
    abort();
  }

  esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
  logHeapAndStack("ble:init:before_bt_controller_init");
  ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
  ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
  ESP_ERROR_CHECK(esp_bluedroid_init());
  ESP_ERROR_CHECK(esp_bluedroid_enable());
  logHeapAndStack("ble:init:after_bluedroid_enable");

  esp_ble_gatts_register_callback(gattsEventHandler);
  esp_ble_gap_register_callback(gapEventHandler);
  esp_ble_gatts_app_register(0);
}

void setup() {
  Serial.begin(115200);
  logHeapAndStack("setup:after_serial");

  setupMotors();
}

void loop() {
  if (g_motor_left_ready) {
    g_motor_left.loopFOC();
    g_motor_left.move();
  }

  if (g_motor_right_ready) {
    g_motor_right.loopFOC();
    g_motor_right.move();
  }

  odometryUpdateTick();
  bleUploadLoop();
}

extern "C" void app_main() {
  logHeapAndStack("app_main:entry");
  initBleStack();
  logHeapAndStack("app_main:after_ble_init");

  initArduino();
  logHeapAndStack("app_main:after_initArduino");
  if (!heap_caps_check_integrity_all(true)) {
    ESP_LOGE(kDiagTag, "Heap integrity check failed after initArduino");
    abort();
  }
  setup();
  while (true) {
    loop();
    vTaskDelay(1);
  }
}

#pragma GCC diagnostic pop
