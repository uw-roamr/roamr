#include "semantic/bbox_lidar_correspondence.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

#include "core/math_utils.h"

namespace semantic {
namespace {

struct MatchedPoint {
  core::Vector3d body_point{};
  int32_t pixel_x = 0;
  int32_t pixel_y = 0;
  float range_m = 0.0f;
  float center_dist2 = 0.0f;
};

bool is_normalized_box(const ml::Detection& detection) {
  return detection.x_min >= -0.5f && detection.y_min >= -0.5f &&
         detection.x_max <= 1.5f && detection.y_max <= 1.5f;
}

}  // namespace

bool pose_log_valid(const sensors::PoseLog& pose) {
  const double q_norm2 =
      pose.quaternion.x * pose.quaternion.x +
      pose.quaternion.y * pose.quaternion.y +
      pose.quaternion.z * pose.quaternion.z +
      pose.quaternion.w * pose.quaternion.w;
  return pose.timestamp > 0.0 && q_norm2 > 1e-6;
}

bool detection_to_bounding_box_pixels(
    const ml::RunLatestCameraFrameRequest& request,
    const ml::Detection& detection,
    BoundingBoxPixels* out_box) {
  if (!out_box || request.image_width <= 0 || request.image_height <= 0) {
    return false;
  }

  const bool normalized = is_normalized_box(detection);
  const float x_scale =
      normalized ? static_cast<float>(request.image_width) : 1.0f;
  const float y_scale =
      normalized ? static_cast<float>(request.image_height) : 1.0f;

  const float raw_x0 = detection.x_min * x_scale;
  const float raw_y0 = detection.y_min * y_scale;
  const float raw_x1 = detection.x_max * x_scale;
  const float raw_y1 = detection.y_max * y_scale;

  const int32_t max_x = std::max(0, request.image_width - 1);
  const int32_t max_y = std::max(0, request.image_height - 1);
  const int32_t x_min = std::clamp(
      static_cast<int32_t>(std::floor(std::min(raw_x0, raw_x1))), 0, max_x);
  const int32_t y_min = std::clamp(
      static_cast<int32_t>(std::floor(std::min(raw_y0, raw_y1))), 0, max_y);
  const int32_t x_max = std::clamp(
      static_cast<int32_t>(std::ceil(std::max(raw_x0, raw_x1))), 0, max_x);
  const int32_t y_max = std::clamp(
      static_cast<int32_t>(std::ceil(std::max(raw_y0, raw_y1))), 0, max_y);
  if (x_min > x_max || y_min > y_max) {
    return false;
  }

  out_box->x_min = x_min;
  out_box->y_min = y_min;
  out_box->x_max = x_max;
  out_box->y_max = y_max;
  out_box->center_x = x_min + (x_max - x_min) / 2;
  out_box->center_y = y_min + (y_max - y_min) / 2;
  return true;
}

core::Vector3d lidar_point_to_body_point(float x, float y, float z) {
  return core::Vector3d{x, -z, y};
}

core::Vector3d body_point_to_world_point(
    const core::Vector3d& body_point,
    const sensors::PoseLog& pose) {
  core::Vector3d world_point = core::quat_rotate(
      core::quat_normalize(pose.quaternion),
      body_point);
  world_point += pose.translation;
  return world_point;
}

bool query_lidar_bbox_coordinates(
    const sensors::LidarCameraDataV2& lidar_data,
    const BoundingBoxPixels& box,
    LidarBoundingBoxQueryResult* out_result) {
  if (!out_result) {
    return false;
  }

  const size_t point_count = std::min(
      lidar_data.points_size / sensors::float_per_point,
      lidar_data.pixel_coords_size / sensors::pixel_coord_components);
  if (point_count == 0) {
    return false;
  }

  std::vector<MatchedPoint> matches;
  matches.reserve(64);

  for (size_t point_idx = 0; point_idx < point_count; ++point_idx) {
    const size_t point_base = point_idx * sensors::float_per_point;
    const size_t pixel_base = point_idx * sensors::pixel_coord_components;
    const int32_t pixel_x = lidar_data.pixel_coords[pixel_base + 0];
    const int32_t pixel_y = lidar_data.pixel_coords[pixel_base + 1];
    if (pixel_x < box.x_min || pixel_x > box.x_max ||
        pixel_y < box.y_min || pixel_y > box.y_max) {
      continue;
    }

    const float x = lidar_data.points[point_base + 0];
    const float y = lidar_data.points[point_base + 1];
    const float z = lidar_data.points[point_base + 2];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
      continue;
    }

    const core::Vector3d body_point = lidar_point_to_body_point(x, y, z);
    const float range_m = static_cast<float>(
        std::sqrt(body_point.x * body_point.x +
                  body_point.y * body_point.y +
                  body_point.z * body_point.z));
    const float dx = static_cast<float>(pixel_x - box.center_x);
    const float dy = static_cast<float>(pixel_y - box.center_y);

    MatchedPoint match{};
    match.body_point = body_point;
    match.pixel_x = pixel_x;
    match.pixel_y = pixel_y;
    match.range_m = range_m;
    match.center_dist2 = dx * dx + dy * dy;
    matches.push_back(match);
  }

  if (matches.empty()) {
    return false;
  }

  std::vector<float> ranges;
  ranges.reserve(matches.size());
  for (const MatchedPoint& match : matches) {
    ranges.push_back(match.range_m);
  }
  const size_t median_idx = ranges.size() / 2;
  std::nth_element(ranges.begin(), ranges.begin() + median_idx, ranges.end());
  const float median_range_m = ranges[median_idx];
  const float inlier_range_threshold_m =
      std::max(0.08f, median_range_m * 0.15f);

  core::Vector3d inlier_sum{};
  int32_t inlier_count = 0;
  float best_inlier_center_dist2 = std::numeric_limits<float>::infinity();
  int32_t best_pixel_x = matches.front().pixel_x;
  int32_t best_pixel_y = matches.front().pixel_y;
  for (const MatchedPoint& match : matches) {
    if (std::fabs(match.range_m - median_range_m) > inlier_range_threshold_m) {
      continue;
    }
    inlier_sum += match.body_point;
    ++inlier_count;
    if (match.center_dist2 < best_inlier_center_dist2) {
      best_inlier_center_dist2 = match.center_dist2;
      best_pixel_x = match.pixel_x;
      best_pixel_y = match.pixel_y;
    }
  }

  if (inlier_count <= 0) {
    return false;
  }

  out_result->body_point = core::Vector3d{
      inlier_sum.x / static_cast<double>(inlier_count),
      inlier_sum.y / static_cast<double>(inlier_count),
      inlier_sum.z / static_cast<double>(inlier_count)};
  out_result->pixel_x = best_pixel_x;
  out_result->pixel_y = best_pixel_y;
  out_result->matched_points = static_cast<int32_t>(matches.size());
  out_result->inlier_points = inlier_count;
  out_result->lidar_timestamp = lidar_data.timestamp;
  out_result->used_bbox_match = true;
  return true;
}

}  // namespace semantic
