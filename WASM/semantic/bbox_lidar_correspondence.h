#pragma once

#include <cstdint>

#include "core/pose/se3.h"
#include "ml/model.h"
#include "sensors/imu_preintegration.h"
#include "sensors/lidar_camera.h"

namespace semantic {

struct BoundingBoxPixels {
  int32_t x_min = 0;
  int32_t y_min = 0;
  int32_t x_max = 0;
  int32_t y_max = 0;
  int32_t center_x = 0;
  int32_t center_y = 0;
};

struct LidarBoundingBoxQueryResult {
  core::Vector3d body_point{};
  int32_t pixel_x = 0;
  int32_t pixel_y = 0;
  int32_t matched_points = 0;
  int32_t inlier_points = 0;
  double lidar_timestamp = 0.0;
  bool used_bbox_match = false;
};

bool pose_log_valid(const sensors::PoseLog& pose);
bool detection_to_bounding_box_pixels(
    const ml::RunLatestCameraFrameRequest& request,
    const ml::Detection& detection,
    BoundingBoxPixels* out_box);
bool query_lidar_bbox_coordinates(
    const sensors::LidarCameraDataV2& lidar_data,
    const BoundingBoxPixels& box,
    LidarBoundingBoxQueryResult* out_result);
core::Vector3d lidar_point_to_body_point(float x, float y, float z);
core::Vector3d body_point_to_world_point(
    const core::Vector3d& body_point,
    const sensors::PoseLog& pose);

}  // namespace semantic
