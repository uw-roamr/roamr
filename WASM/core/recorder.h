#pragma once

#include <cstdint>

#include "sensors/imu.h"
#include "sensors/imu_preintegration.h"
#include "sensors/lidar_camera.h"

namespace core::recorder {

enum class PoseDataSource : uint32_t {
  kUnspecified = 0,
  kIMU = 1,
  kWheelOdometry = 2,
  kFusedImuWheelOdometry = 3,
};

void initialize_from_env(const sensors::CameraConfig& camera_config);
bool is_enabled();

void enqueue_imu(const sensors::IMUData& data);
void enqueue_pose(const sensors::PoseLog& pose, PoseDataSource source);
void enqueue_lidar_frame(
    const sensors::LidarCameraData& data,
    const sensors::PoseLog& pose);
}  // namespace core::recorder
