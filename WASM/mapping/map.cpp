// WASM helpers to accept multiple poses and render a simple RGBA map image.
// Coordinate space: inputs are (x, y, theta) in meters; LiDAR points are (x, y) in meters.
// Map is a fixed-size occupancy grid (similar to the ROS node).
#include "mapping/map.h"

#include <cmath>

namespace mapping {

void Map::reset_poses() {
  poses_.fill(0.0);
}

void Map::reset_points() {
  points_.fill(0.0f);
  points_count_ = 0;
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
  const int32_t base = idx * 3;
  poses_[base + 0] = x;
  poses_[base + 1] = y;
  poses_[base + 2] = theta;
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

void Map::integrate_scan(
    double pose_x,
    double pose_y,
    double pose_theta,
    int32_t point_count,
    int32_t points_in_world) {
  if (point_count <= 0) {
    return;
  }
  maybe_init_origin(pose_x, pose_y);

  int32_t start_x = 0;
  int32_t start_y = 0;
  if (!world_to_grid(pose_x, pose_y, &start_x, &start_y)) {
    return;
  }

  const double min_range2 = static_cast<double>(kMinRange) * static_cast<double>(kMinRange);
  const double c = std::cos(pose_theta);
  const double s = std::sin(pose_theta);

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
      wx = pose_x + c * lx - s * ly;
      wy = pose_y + s * lx + c * ly;
    }

    const double dx = wx - pose_x;
    const double dy = wy - pose_y;
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

void Map::set_pixel(int32_t x, int32_t y, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  if (x < 0 || x >= cur_w_ || y < 0 || y >= cur_h_) {
    return;
  }
  const int32_t offset = (y * cur_w_ + x) * 4;
  image_[offset + 0] = r;
  image_[offset + 1] = g;
  image_[offset + 2] = b;
  image_[offset + 3] = a;
}

int32_t Map::grid_to_pixel(
    int32_t gx,
    int32_t gy,
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
  if (ix < 0 || ix >= cur_w_ || iy < 0 || iy >= cur_h_) {
    return 0;
  }
  *px = ix;
  *py = iy;
  return 1;
}

void Map::draw_map(int32_t pose_count, int32_t point_count, int32_t width, int32_t height) {
  if (pose_count < 0) {
    pose_count = 0;
  }
  if (pose_count > kMaxMapPoses) {
    pose_count = kMaxMapPoses;
  }
  if (point_count < 0) {
    point_count = 0;
  }
  if (point_count > kMaxMapPoints) {
    point_count = kMaxMapPoints;
  }
  if (width <= 0) {
    width = 256;
  }
  if (height <= 0) {
    height = 256;
  }
  if (width > kMaxImageWidth) {
    width = kMaxImageWidth;
  }
  if (height > kMaxImageHeight) {
    height = kMaxImageHeight;
  }
  cur_w_ = width;
  cur_h_ = height;

  const int32_t used_points = (point_count < points_count_) ? point_count : points_count_;
  if (used_points > 0 && pose_count > 0) {
    const int32_t base = (pose_count - 1) * 3;
    integrate_scan(
        poses_[base + 0],
        poses_[base + 1],
        poses_[base + 2],
        used_points,
        points_in_world_);
  }

  const float scale_x = static_cast<float>(cur_w_) / static_cast<float>(kMapSizeX);
  const float scale_y = static_cast<float>(cur_h_) / static_cast<float>(kMapSizeY);
  const float scale = (scale_x < scale_y) ? scale_x : scale_y;
  const float off_x = (static_cast<float>(cur_w_) - static_cast<float>(kMapSizeX) * scale) * 0.5f;
  const float off_y = (static_cast<float>(cur_h_) - static_cast<float>(kMapSizeY) * scale) * 0.5f;

  for (int32_t py = 0; py < cur_h_; ++py) {
    for (int32_t px = 0; px < cur_w_; ++px) {
      const int32_t gx = static_cast<int32_t>((static_cast<float>(px) - off_x) / scale);
      const int32_t gy =
          kMapSizeY - 1 - static_cast<int32_t>((static_cast<float>(py) - off_y) / scale);

      uint8_t v = 128;
      if (gx >= 0 && gx < kMapSizeX && gy >= 0 && gy < kMapSizeY) {
        const int32_t idx = grid_index(gx, gy);
        if (visited_[idx]) {
          v = confirmed_[idx] ? 255 : 0;
        }
      }

      const int32_t offset = (py * cur_w_ + px) * 4;
      image_[offset + 0] = v;
      image_[offset + 1] = v;
      image_[offset + 2] = v;
      image_[offset + 3] = 255;
    }
  }

  if (pose_count > 0) {
    const int32_t base = (pose_count - 1) * 3;
    int32_t gx = 0;
    int32_t gy = 0;
    if (world_to_grid(poses_[base + 0], poses_[base + 1], &gx, &gy)) {
      int32_t ppx = 0;
      int32_t ppy = 0;
      if (grid_to_pixel(gx, gy, scale, off_x, off_y, &ppx, &ppy)) {
        for (int32_t dy = -1; dy <= 1; ++dy) {
          for (int32_t dx = -1; dx <= 1; ++dx) {
            set_pixel(ppx + dx, ppy + dy, 0, 255, 0, 255);
          }
        }
      }
    }
  }
}

int32_t Map::get_image_width() const {
  return cur_w_;
}

int32_t Map::get_image_height() const {
  return cur_h_;
}

uint8_t* Map::get_image_rgba_ptr() {
  return image_.data();
}

int32_t Map::get_image_rgba_size() const {
  return cur_w_ * cur_h_ * 4;
}

int32_t Map::get_image_pixel_u32(int32_t index) const {
  if (index < 0 || index >= (cur_w_ * cur_h_)) {
    return 0;
  }
  const int32_t offset = index * 4;
  const uint32_t r = image_[offset + 0];
  const uint32_t g = image_[offset + 1];
  const uint32_t b = image_[offset + 2];
  const uint32_t a = image_[offset + 3];
  const uint32_t packed = (a << 24) | (b << 16) | (g << 8) | r;
  return static_cast<int32_t>(packed);
}

}  // namespace mapping
