#pragma once
#include <mutex>
#include <thread>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <string>

#include "sensors/imu.h"
#include "sensors/imu_preintegration.h"
#include "sensors/lidar_camera.h"

constexpr int log_interval_ms = 33;
constexpr double kLidarLogIntervalSec = 1.0 / 3.0;
constexpr size_t kWasmTextLogMaxBytes = 255;

struct WasmTextLog {
  uint32_t length;
  char text[kWasmTextLogMaxBytes + 1];
};

WASM_IMPORT("host", "host_log_lidar_frame") void host_log_lidar_frame(const sensors::LidarCameraData *data);
WASM_IMPORT("host", "host_log_imu") void host_log_imu(const sensors::IMUData* data);
WASM_IMPORT("host", "host_log_pose") void host_log_pose(const sensors::PoseLog* data);
WASM_IMPORT("host", "host_log_pose_wheel") void host_log_pose_wheel(const sensors::PoseLog* data);
WASM_IMPORT("host", "wasm_log_text") void wasm_log_text(const WasmTextLog* data);

void log_config(const sensors::CameraConfig& cam_config);

void wasm_log_line(const char* text);
void wasm_log_line(const std::string& text);
