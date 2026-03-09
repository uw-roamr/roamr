// WASM helpers to accept multiple poses and render a simple RGBA map image.
// Coordinate space: inputs are (x, y, theta) in meters; LiDAR points are (x, y) in meters.
// Map is a fixed-size occupancy grid (similar to the ROS node).
#include "mapping/map.h"

#include <cmath>

namespace mapping {

void Map::reset_poses() {
  poses_.fill(core::PoseSE2d{});
}

void Map::reset_points() {
  points_.fill(0.0f);
  points_count_ = 0;
}

void Map::reset_free_points() {
  free_points_.fill(0.0f);
  free_points_count_ = 0;
}

void Map::reset_map() {
  scan_count_.fill(0);
  confirmed_.fill(0);
  visited_.fill(0);
  map_origin_initialized_ = 0;
  map_origin_offset_x_ = 0.0f;
  map_origin_offset_y_ = 0.0f;
}

int32_t Map::get_occupancy_grid(int8_t* out_data, int32_t max_cells) const {
  const int32_t total = kMapSizeX * kMapSizeY;
  if (!out_data || max_cells < total) {
    return 0;
  }
  for (int32_t gy = 0; gy < kMapSizeY; ++gy) {
    for (int32_t gx = 0; gx < kMapSizeX; ++gx) {
      const int32_t idx = gx + gy * kMapSizeX;
      int8_t value = -1;
      if (visited_[idx]) {
        value = confirmed_[idx] ? 100 : 0;
      }
      out_data[idx] = value;
    }
  }
  return total;
}

int32_t Map::get_occupancy_meta(OccupancyGridMetadata* out_meta) const {
  if (!out_meta) {
    return 0;
  }
  out_meta->width = kMapSizeX;
  out_meta->height = kMapSizeY;
  out_meta->resolution_m = kGridResolution;
  out_meta->origin_x_m =
      -((double)kMapSizeX * 0.5 * kGridResolution) + map_origin_offset_x_;
  out_meta->origin_y_m =
      -((double)kMapSizeY * 0.5 * kGridResolution) + map_origin_offset_y_;
  out_meta->origin_initialized = map_origin_initialized_ ? 1 : 0;
  return 1;
}

void Map::clear_planned_path() {
  planned_path_count_ = 0;
  planned_goal_enabled_ = 0;
}

void Map::set_planned_path_cell(int32_t idx, int32_t gx, int32_t gy) {
  if (idx < 0 || idx >= kMaxPlannedPath) {
    return;
  }
  const int32_t base = idx * 2;
  planned_path_[base + 0] = gx;
  planned_path_[base + 1] = gy;
  if (idx + 1 > planned_path_count_) {
    planned_path_count_ = idx + 1;
  }
}

void Map::set_planned_goal_cell(int32_t gx, int32_t gy, int32_t enabled) {
  planned_goal_x_ = gx;
  planned_goal_y_ = gy;
  planned_goal_enabled_ = enabled ? 1 : 0;
}

void Map::set_points_world(int32_t in_world) {
  points_in_world_ = in_world ? 1 : 0;
}

void Map::set_pose(int32_t idx, double x, double y, double theta) {
  if (idx < 0 || idx >= kMaxMapPoses) {
    return;
  }
  poses_[idx] = core::PoseSE2d{x, y, theta};
}

void Map::set_point(int32_t idx, double x, double y) {
  if (idx < 0 || idx >= kMaxMapPoints) {
    return;
  }
  const int32_t base = idx * 2;
  points_[base + 0] = static_cast<float>(x);
  points_[base + 1] = static_cast<float>(y);
  if (idx + 1 > points_count_) {
    points_count_ = idx + 1;
  }
}

void Map::set_free_point(int32_t idx, double x, double y) {
  if (idx < 0 || idx >= kMaxFreeRays) {
    return;
  }
  const int32_t base = idx * 2;
  free_points_[base + 0] = static_cast<float>(x);
  free_points_[base + 1] = static_cast<float>(y);
  if (idx + 1 > free_points_count_) {
    free_points_count_ = idx + 1;
  }
}

int32_t Map::is_finite(float v) {
  return std::isfinite(v) ? 1 : 0;
}

int32_t Map::grid_index(int32_t gx, int32_t gy) const {
  return gx + gy * kMapSizeX;
}

int32_t Map::world_to_grid(double x, double y, int32_t* gx, int32_t* gy) const {
  if (map_origin_initialized_) {
    x -= map_origin_offset_x_;
    y -= map_origin_offset_y_;
  }
  const int32_t ix = static_cast<int32_t>(x / kGridResolution) + kMapSizeX / 2;
  const int32_t iy = static_cast<int32_t>(y / kGridResolution) + kMapSizeY / 2;
  if (ix < 0 || ix >= kMapSizeX || iy < 0 || iy >= kMapSizeY) {
    return 0;
  }
  *gx = ix;
  *gy = iy;
  return 1;
}

void Map::maybe_init_origin(double x, double y) {
  if (!map_origin_initialized_) {
    map_origin_offset_x_ = static_cast<float>(x);
    map_origin_offset_y_ = static_cast<float>(y);
    map_origin_initialized_ = 1;
  }
}

void Map::integrate_ray(int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
  int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
  int sx = (x0 < x1) ? 1 : -1;
  int dy = (y1 > y0) ? (y0 - y1) : (y1 - y0);  // negative
  int sy = (y0 < y1) ? 1 : -1;
  int err = dx + dy;

  int x = x0;
  int y = y0;
  while (1) {
    const int32_t idx = grid_index(x, y);
    visited_[idx] = 1;

    if (x == x1 && y == y1) {
      int16_t count = scan_count_[idx];
      if (count < kScanThreshold) {
        count += 1;
      }
      scan_count_[idx] = count;
      if (count >= kScanThreshold) {
        confirmed_[idx] = 1;
      }
      break;
    } else {
      int16_t count = scan_count_[idx];
      count = static_cast<int16_t>((count > kDecayFactor) ? (count - kDecayFactor) : 0);
      scan_count_[idx] = count;
      if (confirmed_[idx] && count < kClearThreshold) {
        confirmed_[idx] = 0;
      }
    }

    const int e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y += sy;
    }
  }
}

void Map::integrate_free_ray(int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
  int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
  int sx = (x0 < x1) ? 1 : -1;
  int dy = (y1 > y0) ? (y0 - y1) : (y1 - y0);  // negative
  int sy = (y0 < y1) ? 1 : -1;
  int err = dx + dy;
  int x = x0;
  int y = y0;
  while (1) {
    const int32_t idx = grid_index(x, y);
    visited_[idx] = 1;
    // Every cell along a free ray — including the endpoint — only receives
    // free-space evidence (decay). No occupancy hit is registered.
    int16_t count = scan_count_[idx];
    count = static_cast<int16_t>((count > kDecayFactor) ? (count - kDecayFactor) : 0);
    scan_count_[idx] = count;
    if (confirmed_[idx] && count < kClearThreshold) {
      confirmed_[idx] = 0;
    }
    if (x == x1 && y == y1) break;
    const int e2 = 2 * err;
    if (e2 >= dy) { err += dy; x += sx; }
    if (e2 <= dx) { err += dx; y += sy; }
  }
}

void Map::integrate_scan(
	const core::PoseSE2d& pose,
    int32_t point_count,
    int32_t points_in_world) {
  if (point_count <= 0) {
    return;
  }
  maybe_init_origin(pose.x, pose.y);

  int32_t start_x = 0;
  int32_t start_y = 0;
  if (!world_to_grid(pose.x, pose.y, &start_x, &start_y)) {
    return;
  }

  const double min_range2 = static_cast<double>(kMinRange) * static_cast<double>(kMinRange);
  const double c = std::cos(pose.theta);
  const double s = std::sin(pose.theta);

  for (int32_t i = 0; i < point_count; ++i) {
    const int32_t base = i * 2;
    const float lx = points_[base + 0];
    const float ly = points_[base + 1];
    if (!is_finite(lx) || !is_finite(ly)) {
      continue;
    }

    double wx = lx;
    double wy = ly;
    if (!points_in_world) {
      wx = pose.x + c * lx - s * ly;
      wy = pose.y + s * lx + c * ly;
    }

    const double dx = wx - pose.x;
    const double dy = wy - pose.y;
    if ((dx * dx + dy * dy) < min_range2) {
      continue;
    }

    int32_t end_x = 0;
    int32_t end_y = 0;
    if (!world_to_grid(wx, wy, &end_x, &end_y)) {
      continue;
    }

    integrate_ray(start_x, start_y, end_x, end_y);
  }
}

void Map::integrate_free_scan(const core::PoseSE2d& pose, int32_t free_point_count) {
  if (free_point_count <= 0) return;
  int32_t start_x = 0, start_y = 0;
  if (!world_to_grid(pose.x, pose.y, &start_x, &start_y)) return;

  for (int32_t i = 0; i < free_point_count; ++i) {
    const int32_t base = i * 2;
    const float wx = free_points_[base + 0];
    const float wy = free_points_[base + 1];
    if (!is_finite(wx) || !is_finite(wy)) continue;
    int32_t end_x = 0, end_y = 0;
    if (!world_to_grid(static_cast<double>(wx), static_cast<double>(wy), &end_x, &end_y)) continue;
    integrate_free_ray(start_x, start_y, end_x, end_y);
  }
}

int32_t Map::grid_to_pixel(
    int32_t gx,
    int32_t gy,
    int32_t img_w,
    int32_t img_h,
    float scale,
    float off_x,
    float off_y,
    int32_t* px,
    int32_t* py) const {
  if (gx < 0 || gx >= kMapSizeX || gy < 0 || gy >= kMapSizeY) {
    return 0;
  }
  const float fx = off_x + (static_cast<float>(gx) + 0.5f) * scale;
  const float fy = off_y + (static_cast<float>(kMapSizeY - 1 - gy) + 0.5f) * scale;
  const int32_t ix = static_cast<int32_t>(fx);
  const int32_t iy = static_cast<int32_t>(fy);
  if (ix < 0 || ix >= img_w || iy < 0 || iy >= img_h) {
    return 0;
  }
  *px = ix;
  *py = iy;
  return 1;
}

void Map::draw_map(int32_t pose_count, int32_t point_count, int32_t free_point_count) {
  if (pose_count < 0) pose_count = 0;
  if (pose_count > kMaxMapPoses) pose_count = kMaxMapPoses;
  if (point_count < 0) point_count = 0;
  if (point_count > kMaxMapPoints) point_count = kMaxMapPoints;
  if (free_point_count < 0) free_point_count = 0;
  if (free_point_count > kMaxFreeRays) free_point_count = kMaxFreeRays;

  const int32_t used_points = (point_count    < points_count_)      ? point_count    : points_count_;
  const int32_t used_free   = (free_point_count < free_points_count_) ? free_point_count : free_points_count_;

  if (pose_count > 0) {
    const core::PoseSE2d& p = poses_[pose_count - 1];
    if (used_points > 0) {
      integrate_scan(p, used_points, points_in_world_);
    }
    if (used_free > 0) {
      integrate_free_scan(p, used_free);
    }
  }

  // Rendering is handled by visualization::render_map_frame.
}

void Map::compute_viewport(int32_t width, int32_t height, float& scale, float& off_x, float& off_y) {
  const float scale_x = static_cast<float>(width)  / static_cast<float>(kMapSizeX);
  const float scale_y = static_cast<float>(height) / static_cast<float>(kMapSizeY);
  scale = (scale_x < scale_y) ? scale_x : scale_y;
  off_x = (static_cast<float>(width)  - static_cast<float>(kMapSizeX) * scale) * 0.5f;
  off_y = (static_cast<float>(height) - static_cast<float>(kMapSizeY) * scale) * 0.5f;
}

}  // namespace mapping
