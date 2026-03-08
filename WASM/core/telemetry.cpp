#include "core/telemetry.h"
#include <algorithm>
#include <cstring>
#include <math.h>
#include <mutex>
#include <stdint.h>

void wasm_log_line(const char* text) {
  if (!text) {
    return;
  }
  WasmTextLog payload{};
  const size_t len = std::min(strlen(text), kWasmTextLogMaxBytes);
  if (len > 0) {
    memcpy(payload.text, text, len);
  }
  payload.text[len] = '\0';
  payload.length = static_cast<uint32_t>(len);
  wasm_log_text(&payload);
}

void wasm_log_line(const std::string& text) {
  wasm_log_line(text.c_str());
}

void log_config(const sensors::CameraConfig& cam_config){
  wasm_log_line("Sensor config initialized");
}


void log_imu(std::mutex& m_imu, const sensors::IMUData& imu_copy, double& last_imu_timestamp){
  std::cout << std::fixed << std::setprecision(5);
  
  if (imu_copy.timestamp <= last_imu_timestamp) {
    std::this_thread::yield();
    return;
  }
  last_imu_timestamp = imu_copy.timestamp;
  rerun_log_imu(&imu_copy);
  // std::cout << "T:" << imu_copy.timestamp << " acc:" << imu_copy.acc_x << "," << imu_copy.acc_y << "," << imu_copy.acc_z << std::endl
  // << "T:" << imu_copy.timestamp << " gyro:" << imu_copy.gyro_x << "," << imu_copy.gyro_y << "," << imu_copy.gyro_z <<
  // std::endl;
}
