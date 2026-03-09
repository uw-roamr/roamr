#pragma once

#include <algorithm>
#include <cstdint>
#include <vector>

#include "core/pose/se2.h"
#include "mapping/map_metadata.h"

namespace mapping {

constexpr int32_t kMaxPoseTrailPoints = 4096;

struct MapSnapshot {
  OccupancyGridMetadata meta{};
  std::vector<int8_t> occupancy;
  core::PoseSE2d pose{};
  double timestamp = 0.0;
  uint64_t map_revision = 0;

  bool valid() const {
    return meta.width > 0 &&
           meta.height > 0 &&
           meta.resolution_m > 0.0 &&
           occupancy.size() == static_cast<size_t>(meta.width * meta.height);
  }
};

struct PoseTrailState {
  std::vector<core::PoseSE2d> poses;
  uint64_t last_map_revision = 0;
};

inline void append_pose_to_trail(
    const MapSnapshot& snapshot,
    PoseTrailState* trail) {
  if (!trail || !snapshot.valid() || snapshot.map_revision <= trail->last_map_revision) {
    return;
  }
  if (trail->poses.size() >= static_cast<size_t>(kMaxPoseTrailPoints)) {
    trail->poses.erase(trail->poses.begin());
  }
  trail->poses.push_back(snapshot.pose);
  trail->last_map_revision = snapshot.map_revision;
}

inline void compute_snapshot_viewport(
    const OccupancyGridMetadata& meta,
    int32_t width,
    int32_t height,
    float* scale,
    float* off_x,
    float* off_y) {
  if (!scale || !off_x || !off_y || meta.width <= 0 || meta.height <= 0) {
    return;
  }
  const float scale_x = static_cast<float>(width) / static_cast<float>(meta.width);
  const float scale_y = static_cast<float>(height) / static_cast<float>(meta.height);
  *scale = std::min(scale_x, scale_y);
  *off_x = (static_cast<float>(width) - static_cast<float>(meta.width) * (*scale)) * 0.5f;
  *off_y = (static_cast<float>(height) - static_cast<float>(meta.height) * (*scale)) * 0.5f;
}

inline bool snapshot_grid_to_pixel(
    const OccupancyGridMetadata& meta,
    int32_t gx,
    int32_t gy,
    int32_t img_w,
    int32_t img_h,
    float scale,
    float off_x,
    float off_y,
    int32_t* px,
    int32_t* py) {
  if (!px || !py || gx < 0 || gx >= meta.width || gy < 0 || gy >= meta.height) {
    return false;
  }
  const float fx = off_x + (static_cast<float>(gx) + 0.5f) * scale;
  const float fy = off_y + (static_cast<float>(meta.height - 1 - gy) + 0.5f) * scale;
  const int32_t ix = static_cast<int32_t>(fx);
  const int32_t iy = static_cast<int32_t>(fy);
  if (ix < 0 || ix >= img_w || iy < 0 || iy >= img_h) {
    return false;
  }
  *px = ix;
  *py = iy;
  return true;
}

}  // namespace mapping
