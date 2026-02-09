#pragma once
#include <mutex>
#include <thread>
#include <chrono>
#include <iomanip>
#include <iostream>

#include "sensors/imu.h"
#include "sensors/lidar_camera.h"
#include "frontend/corner_detection.h"

constexpr int log_interval_ms = 33;

WASM_IMPORT("host", "rerun_log_lidar_frame") void rerun_log_lidar_frame(const LidarCameraData *data);
WASM_IMPORT("host", "rerun_log_camera_keypoints") void rerun_log_camera_keypoints(const LidarCameraData *data, const std::vector<Keypoint2d>* keypoints);

void log_config(const CameraConfig& cam_config);
void log_lc(std::mutex& m_lc, const LidarCameraData& lc_data, const std::vector<Keypoint2d>& keypoints2d);
