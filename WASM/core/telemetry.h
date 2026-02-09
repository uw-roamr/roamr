#pragma once
#include <mutex>
#include <thread>
#include <chrono>
#include <iomanip>
#include <iostream>

#include "sensors/imu.h"
#include "sensors/lidar_camera.h"

constexpr int log_interval_ms = 33;
constexpr double kLidarLogIntervalSec = 0.1;

WASM_IMPORT("host", "rerun_log_lidar_frame") void rerun_log_lidar_frame(const sensors::LidarCameraData *data);
WASM_IMPORT("host", "rerun_log_imu") void rerun_log_imu(const sensors::IMUData* data);

void log_config(const sensors::CameraConfig& cam_config);

void log_imu(std::mutex& m_imu, const sensors::IMUData& imu_data, double& last_imu_timestamp);
void log_lc(std::mutex& m_lc, const sensors::LidarCameraData& lc_data, double& last_lc_timestamp);


