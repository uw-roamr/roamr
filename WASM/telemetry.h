#pragma once
#include <mutex>
#include <thread>
#include <chrono>
#include <iomanip>
#include <iostream>

#include "imu.h"
#include "lidar_camera.h"

constexpr int log_interval_ms = 33;

void log_config(const CameraConfig& cam_config);
void log_sensors(std::mutex& m_imu, const IMUData& imu_data, std::mutex& m_lc, const LidarCameraData& lc_data);
