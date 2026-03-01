#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"

#include "encoders/as5048a/MagneticSensorAS5048A.h"
#include <Arduino.h>
#include <SPI.h>
#include <SimpleFOC.h>
#include <SimpleFOCDrivers.h>
#include <ctype.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatt_common_api.h"
#include "esp_gatts_api.h"
#ifndef LOG_LOCAL_LEVEL
#define LOG_LOCAL_LEVEL ESP_LOG_ERROR
#endif
#include "esp_log.h"
#include "freertos/task.h"
#include "nvs_flash.h"

extern "C" void __wrap_esp_log_write(esp_log_level_t level, const char *tag,
                                     const char *format, ...) {
  (void)level;
  (void)tag;
  va_list args;
  va_start(args, format);
  vprintf(format, args);
  va_end(args);
}

#define GATTS_TAG "BLE_ODOM"
#define DEVICE_NAME "ESP32_C6"
#define GATTS_SERVICE_UUID 0x00FF
#define GATTS_CONTROL_CHAR_UUID 0xFF01
#define GATTS_DATA_CHAR_UUID 0xFF02
#define GATTS_STATUS_CHAR_UUID 0xFF03
#define GATTS_NUM_HANDLE 10

constexpr uint16_t BLE_DEFAULT_ATT_MTU = 23;
constexpr uint16_t BLE_PREFERRED_ATT_MTU = 185;
constexpr size_t BLE_DATA_CHAR_MAX_LEN = 244;

constexpr size_t ODOM_RING_CAPACITY = 2048;
constexpr uint16_t ODOM_DEFAULT_SAMPLE_PERIOD_MS = 20;
constexpr uint16_t ODOM_MIN_SAMPLE_PERIOD_MS = 5;
constexpr uint16_t ODOM_MAX_SAMPLE_PERIOD_MS = 1000;
constexpr uint8_t ODOM_FRAME_HEADER_SIZE = 3; // seq:uint16 + n:uint8
constexpr uint8_t ODOM_SAMPLE_SIZE = 4;       // dl:int16 + dr:int16
constexpr uint8_t MAX_NOTIFY_FRAMES_PER_LOOP = 4;
constexpr size_t CONTROL_CMD_MAX_LEN = 127;

constexpr int PIN_MOSI = 4;
constexpr int PIN_SCLK = 5;
constexpr int PIN_MISO = 6;
constexpr int PIN_CS1 = 7;
constexpr int PIN_CS2 = 15;

constexpr int PIN_DRIVER1_1 = 0;
constexpr int PIN_DRIVER1_2 = 1;
constexpr int PIN_DRIVER1_3 = 8;
constexpr int PIN_DRIVER1_EN = 10;

constexpr int PIN_DRIVER2_1 = 23;
constexpr int PIN_DRIVER2_2 = 22;
constexpr int PIN_DRIVER2_3 = 21;
constexpr int PIN_DRIVER2_EN = 20;

SPISettings mySPISettings(1000000, MSBFIRST, SPI_MODE1);
MagneticSensorAS5048A sensor1(PIN_CS1, false, mySPISettings);
MagneticSensorAS5048A sensor2(PIN_CS2, false, mySPISettings);

BLDCDriver3PWM driver1(PIN_DRIVER1_1, PIN_DRIVER1_2, PIN_DRIVER1_3,
                       PIN_DRIVER1_EN);
BLDCDriver3PWM driver2(PIN_DRIVER2_1, PIN_DRIVER2_2, PIN_DRIVER2_3,
                       PIN_DRIVER2_EN);
BLDCMotor motor1(7);
BLDCMotor motor2(7);
Commander command = Commander(Serial);

void doMotor1(char *cmd) { command.motor(&motor1, cmd); }
void doMotor2(char *cmd) { command.motor(&motor2, cmd); }

enum class OdomState : uint8_t { IDLE = 0, RECORDING = 1, UPLOADING = 2 };

struct OdomSample {
  int16_t dl_ticks;
  int16_t dr_ticks;
};

struct OdomStatusPayload {
  uint8_t state;
  uint16_t buffered_samples;
  uint16_t dropped_samples;
  uint16_t last_seq;
  uint16_t sample_period_ms;
} __attribute__((packed));

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
static uint16_t g_service_handle = 0;
static uint16_t g_control_char_handle = 0;
static uint16_t g_data_char_handle = 0;
static uint16_t g_data_cccd_handle = 0;
static uint16_t g_status_char_handle = 0;

static esp_gatt_if_t g_ble_gatts_if = ESP_GATT_IF_NONE;
static uint16_t g_ble_conn_id = 0;
static bool g_ble_connected = false;
static bool g_data_notify_enabled = false;
static bool g_ble_congested = false;
static uint16_t g_negotiated_att_mtu = BLE_DEFAULT_ATT_MTU;

static OdomState g_odom_state = OdomState::IDLE;
static OdomSample g_ring_buffer[ODOM_RING_CAPACITY];
static size_t g_ring_head = 0;
static size_t g_ring_tail = 0;
static size_t g_ring_count = 0;
static uint32_t g_dropped_samples = 0;

static uint16_t g_upload_seq = 0;
static uint16_t g_last_uploaded_seq = 0xFFFF;
static uint32_t g_record_until_ms = 0;
static uint16_t g_sample_period_ms = ODOM_DEFAULT_SAMPLE_PERIOD_MS;
static uint32_t g_last_sample_ms = 0;
static bool g_prev_raw_valid = false;
static uint16_t g_prev_left_raw = 0;
static uint16_t g_prev_right_raw = 0;

static bool g_status_dirty = true;

static uint8_t g_control_char_value[CONTROL_CMD_MAX_LEN + 1] = {0};
static uint8_t g_data_char_value[BLE_DATA_CHAR_MAX_LEN] = {0};
static uint8_t g_status_char_value[sizeof(OdomStatusPayload)] = {0};
static uint8_t g_data_cccd_value[2] = {0, 0};

bool init_success = false;
bool motor1_ready = false;
bool motor2_ready = false;

static void markStatusDirty() { g_status_dirty = true; }

static uint16_t clampU16(uint32_t value) {
  return value > 0xFFFFu ? 0xFFFFu : static_cast<uint16_t>(value);
}

static void setOdomState(OdomState state) {
  if (g_odom_state == state) {
    return;
  }
  g_odom_state = state;
  markStatusDirty();
}

static bool timeReached(uint32_t now_ms, uint32_t target_ms) {
  return static_cast<int32_t>(now_ms - target_ms) >= 0;
}

static void odomBufferClear() {
  g_ring_head = 0;
  g_ring_tail = 0;
  g_ring_count = 0;
  g_dropped_samples = 0;
  markStatusDirty();
}

static bool odomBufferPush(const OdomSample &sample) {
  if (g_ring_count >= ODOM_RING_CAPACITY) {
    g_dropped_samples++;
    markStatusDirty();
    return false;
  }

  g_ring_buffer[g_ring_head] = sample;
  g_ring_head = (g_ring_head + 1) % ODOM_RING_CAPACITY;
  g_ring_count++;
  markStatusDirty();
  return true;
}

static OdomSample odomBufferPeek(size_t index) {
  size_t pos = (g_ring_tail + index) % ODOM_RING_CAPACITY;
  return g_ring_buffer[pos];
}

static void odomBufferDrop(size_t count) {
  if (count > g_ring_count) {
    count = g_ring_count;
  }
  g_ring_tail = (g_ring_tail + count) % ODOM_RING_CAPACITY;
  g_ring_count -= count;
  markStatusDirty();
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

static void refreshStatusCharacteristic() {
  if (!g_status_dirty || g_status_char_handle == 0) {
    return;
  }

  OdomStatusPayload payload = {};
  payload.state = static_cast<uint8_t>(g_odom_state);
  payload.buffered_samples = clampU16(g_ring_count);
  payload.dropped_samples = clampU16(g_dropped_samples);
  payload.last_seq = g_last_uploaded_seq;
  payload.sample_period_ms = g_sample_period_ms;

  memcpy(g_status_char_value, &payload, sizeof(payload));
  (void)esp_ble_gatts_set_attr_value(
      g_status_char_handle, sizeof(payload), g_status_char_value);
  g_status_dirty = false;
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

static void startRecording(int duration_ms, int requested_sample_period_ms) {
  if (duration_ms <= 0) {
    return;
  }

  odomBufferClear();
  g_upload_seq = 0;
  g_last_uploaded_seq = 0xFFFF;
  g_sample_period_ms = clampSamplePeriodMs(requested_sample_period_ms);
  g_prev_raw_valid = false;

  uint32_t now = millis();
  g_last_sample_ms = now;
  g_record_until_ms = now + static_cast<uint32_t>(duration_ms);
  setOdomState(OdomState::RECORDING);
}

static void startContinuousStreaming() {
  odomBufferClear();
  g_upload_seq = 0;
  g_last_uploaded_seq = 0xFFFF;
  g_prev_raw_valid = false;
  g_record_until_ms = 0;
  g_last_sample_ms = millis();
  setOdomState(OdomState::RECORDING);
}

static void stopRecordingAndUpload() {
  if (g_odom_state == OdomState::RECORDING || g_ring_count > 0) {
    setOdomState(OdomState::UPLOADING);
  } else {
    setOdomState(OdomState::IDLE);
  }
}

static void clearRecording() {
  odomBufferClear();
  g_upload_seq = 0;
  g_last_uploaded_seq = 0xFFFF;
  g_prev_raw_valid = false;
  setOdomState(OdomState::IDLE);
}

static void handleMotorCommand(const char *cmd) {
  int values[3] = {0, 0, 0};
  if (parseIntTokens(cmd, values, 3) == 3) {
    int left_pct = values[0];
    int right_pct = values[1];
    int duration_ms = values[2];
    float left_voltage = (left_pct / 100.0f) * 12.0f;
    float right_voltage = -(right_pct / 100.0f) * 12.0f;

    motor1.target = left_voltage;
    motor2.target = right_voltage;
    (void)duration_ms;
    return;
  }

  command.run(const_cast<char *>(cmd));
}

static void handleControlCommand(const uint8_t *data, uint16_t len) {
  if (len == 0 || data == nullptr) {
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

  if (strncmp(cmd, "START", 5) == 0) {
    int values[2] = {0, static_cast<int>(ODOM_DEFAULT_SAMPLE_PERIOD_MS)};
    int parsed = parseIntTokens(cmd + 5, values, 2);
    if (parsed >= 1) {
      startRecording(values[0], values[1]);
    }
    return;
  }

  if (strcmp(cmd, "STOP") == 0) {
    stopRecordingAndUpload();
    return;
  }

  if (strcmp(cmd, "CLEAR") == 0) {
    clearRecording();
    return;
  }

  if (strcmp(cmd, "GET_STATUS") == 0) {
    markStatusDirty();
    return;
  }

  handleMotorCommand(cmd);
}

static void addControlCharacteristic() {
  esp_bt_uuid_t char_uuid = {};
  char_uuid.len = ESP_UUID_LEN_16;
  char_uuid.uuid.uuid16 = GATTS_CONTROL_CHAR_UUID;

  esp_attr_value_t control_attr = {};
  control_attr.attr_max_len = sizeof(g_control_char_value);
  control_attr.attr_len = 0;
  control_attr.attr_value = g_control_char_value;

  esp_ble_gatts_add_char(g_service_handle, &char_uuid,
                         ESP_GATT_PERM_WRITE,
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
  data_attr.attr_len = 0;
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

static void addStatusCharacteristic() {
  esp_bt_uuid_t char_uuid = {};
  char_uuid.len = ESP_UUID_LEN_16;
  char_uuid.uuid.uuid16 = GATTS_STATUS_CHAR_UUID;

  esp_attr_value_t status_attr = {};
  status_attr.attr_max_len = sizeof(g_status_char_value);
  status_attr.attr_len = sizeof(g_status_char_value);
  status_attr.attr_value = g_status_char_value;

  esp_ble_gatts_add_char(g_service_handle, &char_uuid, ESP_GATT_PERM_READ,
                         ESP_GATT_CHAR_PROP_BIT_READ, &status_attr, nullptr);
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
  if (g_odom_state != OdomState::RECORDING) {
    return;
  }

  uint32_t now = millis();
  if (!g_prev_raw_valid) {
    g_prev_left_raw = sensor1.readRawAngle();
    g_prev_right_raw = sensor2.readRawAngle();
    g_prev_raw_valid = true;
    g_last_sample_ms = now;
    return;
  }

  if (static_cast<uint32_t>(now - g_last_sample_ms) < g_sample_period_ms) {
    if (g_record_until_ms != 0 && timeReached(now, g_record_until_ms)) {
      setOdomState(OdomState::UPLOADING);
    }
    return;
  }

  uint16_t left_raw = sensor1.readRawAngle();
  uint16_t right_raw = sensor2.readRawAngle();

  OdomSample sample = {};
  sample.dl_ticks = wrappedDeltaTicks(left_raw, g_prev_left_raw);
  sample.dr_ticks = wrappedDeltaTicks(right_raw, g_prev_right_raw);
  odomBufferPush(sample);

  g_prev_left_raw = left_raw;
  g_prev_right_raw = right_raw;
  g_last_sample_ms = now;

  if (g_record_until_ms != 0 && timeReached(now, g_record_until_ms)) {
    setOdomState(OdomState::UPLOADING);
  }
}

static void bleUploadLoop() {
  if (g_odom_state == OdomState::IDLE) {
    return;
  }

  if (g_ring_count == 0 && g_odom_state == OdomState::UPLOADING) {
    setOdomState(OdomState::IDLE);
    return;
  }

  if (!g_ble_connected || !g_data_notify_enabled || g_ble_congested ||
      g_data_char_handle == 0 || g_ble_gatts_if == ESP_GATT_IF_NONE) {
    return;
  }

  size_t max_payload = BLE_DATA_CHAR_MAX_LEN;
  if (g_negotiated_att_mtu > 3) {
    size_t mtu_payload = static_cast<size_t>(g_negotiated_att_mtu - 3);
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

  for (uint8_t frame_idx = 0; frame_idx < MAX_NOTIFY_FRAMES_PER_LOOP;
       frame_idx++) {
    if (g_ring_count == 0 || g_ble_congested) {
      break;
    }

    size_t samples_in_frame = g_ring_count < max_samples ? g_ring_count : max_samples;
    if (samples_in_frame == 0) {
      break;
    }

    frame[0] = static_cast<uint8_t>(g_upload_seq & 0xFF);
    frame[1] = static_cast<uint8_t>((g_upload_seq >> 8) & 0xFF);
    frame[2] = static_cast<uint8_t>(samples_in_frame);

    size_t offset = ODOM_FRAME_HEADER_SIZE;
    for (size_t i = 0; i < samples_in_frame; i++) {
      OdomSample sample = odomBufferPeek(i);

      uint16_t dl = static_cast<uint16_t>(sample.dl_ticks);
      uint16_t dr = static_cast<uint16_t>(sample.dr_ticks);

      frame[offset++] = static_cast<uint8_t>(dl & 0xFF);
      frame[offset++] = static_cast<uint8_t>((dl >> 8) & 0xFF);
      frame[offset++] = static_cast<uint8_t>(dr & 0xFF);
      frame[offset++] = static_cast<uint8_t>((dr >> 8) & 0xFF);
    }

    esp_err_t err = esp_ble_gatts_send_indicate(
        g_ble_gatts_if, g_ble_conn_id, g_data_char_handle, offset, frame, false);
    if (err != ESP_OK) {
      break;
    }

    odomBufferDrop(samples_in_frame);
    g_last_uploaded_seq = g_upload_seq;
    g_upload_seq++;
    markStatusDirty();
  }

  if (g_ring_count == 0 && g_odom_state == OdomState::UPLOADING) {
    setOdomState(OdomState::IDLE);
  }
}

static void gatts_event_handler(esp_gatts_cb_event_t event,
                                esp_gatt_if_t gatts_if,
                                esp_ble_gatts_cb_param_t *param) {
  switch (event) {
  case ESP_GATTS_REG_EVT: {
    g_ble_gatts_if = gatts_if;

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
      ESP_LOGE(GATTS_TAG, "Service create failed: %d", param->create.status);
      break;
    }

    g_service_handle = param->create.service_handle;
    gatts_handle_table[0] = g_service_handle;
    esp_ble_gatts_start_service(g_service_handle);
    addControlCharacteristic();
    break;
  }

  case ESP_GATTS_ADD_CHAR_EVT: {
    if (param->add_char.status != ESP_GATT_OK) {
      ESP_LOGE(GATTS_TAG, "Add char failed: %d", param->add_char.status);
      break;
    }

    uint16_t uuid = param->add_char.char_uuid.uuid.uuid16;
    if (uuid == GATTS_CONTROL_CHAR_UUID) {
      g_control_char_handle = param->add_char.attr_handle;
      gatts_handle_table[1] = g_control_char_handle;
      addDataCharacteristic();
    } else if (uuid == GATTS_DATA_CHAR_UUID) {
      g_data_char_handle = param->add_char.attr_handle;
      gatts_handle_table[2] = g_data_char_handle;
      addDataCccdDescriptor();
    } else if (uuid == GATTS_STATUS_CHAR_UUID) {
      g_status_char_handle = param->add_char.attr_handle;
      gatts_handle_table[3] = g_status_char_handle;
      markStatusDirty();
    }
    break;
  }

  case ESP_GATTS_ADD_CHAR_DESCR_EVT: {
    if (param->add_char_descr.status != ESP_GATT_OK) {
      ESP_LOGE(GATTS_TAG, "Add descriptor failed: %d",
               param->add_char_descr.status);
      break;
    }

    if (param->add_char_descr.descr_uuid.uuid.uuid16 ==
        ESP_GATT_UUID_CHAR_CLIENT_CONFIG) {
      g_data_cccd_handle = param->add_char_descr.attr_handle;
      gatts_handle_table[4] = g_data_cccd_handle;
      addStatusCharacteristic();
    }
    break;
  }

  case ESP_GATTS_CONNECT_EVT:
    g_ble_connected = true;
    g_ble_conn_id = param->connect.conn_id;
    g_ble_gatts_if = gatts_if;
    g_data_notify_enabled = false;
    g_ble_congested = false;
    g_negotiated_att_mtu = BLE_DEFAULT_ATT_MTU;
    markStatusDirty();
    break;

  case ESP_GATTS_DISCONNECT_EVT:
    g_ble_connected = false;
    g_data_notify_enabled = false;
    g_ble_congested = false;
    g_negotiated_att_mtu = BLE_DEFAULT_ATT_MTU;
    clearRecording();
    esp_ble_gap_start_advertising(&adv_params);
    markStatusDirty();
    break;

  case ESP_GATTS_MTU_EVT:
    g_negotiated_att_mtu = param->mtu.mtu;
    break;

  case ESP_GATTS_CONGEST_EVT:
    g_ble_congested = param->congest.congested;
    break;

  case ESP_GATTS_WRITE_EVT: {
    if (param->write.handle == g_data_cccd_handle && param->write.len >= 2) {
      uint16_t cccd = static_cast<uint16_t>(param->write.value[0]) |
                      (static_cast<uint16_t>(param->write.value[1]) << 8);
      g_data_notify_enabled = (cccd & 0x0001u) != 0;
      if (g_data_notify_enabled) {
        startContinuousStreaming();
      } else {
        clearRecording();
      }
      markStatusDirty();
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

static void gap_event_handler(esp_gap_ble_cb_event_t event,
                              esp_ble_gap_cb_param_t *param) {
  switch (event) {
  case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
    esp_ble_gap_start_advertising(&adv_params);
    break;
  case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
    if (param->adv_start_cmpl.status != ESP_BT_STATUS_SUCCESS) {
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

  pinMode(PIN_CS1, OUTPUT);
  digitalWrite(PIN_CS1, HIGH);
  pinMode(PIN_CS2, OUTPUT);
  digitalWrite(PIN_CS2, HIGH);

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

  bool m1_ready = motor1.init();
  bool m2_ready = motor2.init();

  if (!m1_ready) {
    Serial.println("Motor 1 init failed");
  }
  if (!m2_ready) {
    Serial.println("Motor 2 init failed");
  }

  _delay(500);

  if (m1_ready) {
    if (!motor1.initFOC()) {
      Serial.println("FOC 1 failed");
      m1_ready = false;
    }
  }

  _delay(500);

  if (m2_ready) {
    if (!motor2.initFOC()) {
      Serial.println("FOC 2 failed");
      m2_ready = false;
    }
  }

  motor1.target = 0.0;
  motor2.target = 0.0;

  command.add('A', doMotor1, "Motor1");
  command.add('B', doMotor2, "Motor2");
  Serial.println(F("Motor ready."));
  Serial.println(F("Set the target with command A or B:"));

  init_success = true;
  motor1_ready = m1_ready;
  motor2_ready = m2_ready;
}

void loop() {
  if (!init_success) {
    return;
  }

  if (motor1_ready) {
    motor1.loopFOC();
    motor1.move();
  }
  if (motor2_ready) {
    motor2.loopFOC();
    motor2.move();
  }
  command.run();

  odometryUpdateTick();
  bleUploadLoop();
  refreshStatusCharacteristic();
}

extern "C" void app_main() {
  initArduino();
  setup();
  while (true) {
    loop();
    vTaskDelay(1);
  }
}

#pragma GCC diagnostic pop
