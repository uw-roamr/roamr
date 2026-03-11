#pragma once

#include "sensors/imu.h"
#include "sensors/imu_preintegration.h"
#include "sensors/lidar_camera.h"

namespace core::recorder {

void initialize_from_env();
bool is_enabled();

void enqueue_imu(const sensors::IMUData& data);
void enqueue_lidar_frame(
    const sensors::LidarCameraData& data,
    const sensors::PoseLog& pose);
}  // namespace core::recorder
