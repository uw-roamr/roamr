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
constexpr double kLidarLogIntervalSec = 0.1;
constexpr size_t kWasmTextLogMaxBytes = 255;

struct WasmTextLog {
  uint32_t length;
  char text[kWasmTextLogMaxBytes + 1];
};

WASM_IMPORT("host", "rerun_log_lidar_frame") void rerun_log_lidar_frame(const sensors::LidarCameraData *data);
WASM_IMPORT("host", "rerun_log_imu") void rerun_log_imu(const sensors::IMUData* data);
WASM_IMPORT("host", "rerun_log_pose") void rerun_log_pose(const sensors::PoseLog* data);
WASM_IMPORT("host", "rerun_log_pose_wheel") void rerun_log_pose_wheel(const sensors::PoseLog* data);
WASM_IMPORT("host", "wasm_log_text") void wasm_log_text(const WasmTextLog* data);

void log_config(const sensors::CameraConfig& cam_config);

void log_imu(std::mutex& m_imu, const sensors::IMUData& imu_data, double& last_imu_timestamp);
void wasm_log_line(const char* text);
void wasm_log_line(const std::string& text);
