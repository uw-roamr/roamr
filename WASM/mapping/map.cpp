// WASM helpers to accept multiple poses and render a simple RGBA map image.
// Coordinate space: inputs are (x, y, theta) in meters; LiDAR points are (x, y) in meters.
// Map is a fixed-size occupancy grid (similar to the ROS node).
#include "mapping/map.h"

#include <cmath>

namespace mapping {

namespace {

int16_t clamp_cell_score(int value) {
  if (value < Map::kMinCellScore) {
    return Map::kMinCellScore;
  }
  if (value > Map::kMaxCellScore) {
    return Map::kMaxCellScore;
  }
  return static_cast<int16_t>(value);
}

void maybe_record_cell_change(
    int32_t x,
    int32_t y,
    int32_t width,
    bool old_visited,
    bool old_confirmed,
    bool new_visited,
    bool new_confirmed,
    std::vector<planning::GridCoord>* newly_occupied_cells,
    std::vector<uint8_t>* newly_occupied_mask) {
  const bool old_occupied = old_visited && old_confirmed;
  const bool new_occupied = new_visited && new_confirmed;
  if (old_visited == new_visited && old_confirmed == new_confirmed) {
    return;
  }

  const size_t idx = static_cast<size_t>(x + y * width);
  if (!old_occupied && new_occupied && newly_occupied_cells) {
    bool should_append = true;
    if (newly_occupied_mask && idx < newly_occupied_mask->size()) {
      should_append = ((*newly_occupied_mask)[idx] == 0);
      if (should_append) {
        (*newly_occupied_mask)[idx] = 1;
      }
    }
    if (should_append) {
      newly_occupied_cells->push_back(planning::GridCoord{x, y});
    }
  }
}

}  // namespace

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
  hit_cell_scan_stamp_.fill(0);
  current_scan_stamp_ = 0;
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

void Map::set_points_world(int32_t in_world) {
  points_in_world_ = in_world ? 1 : 0;
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

bool Map::begin_scan_integration(
    const core::PoseSE2d& pose,
    int32_t* start_x,
    int32_t* start_y) {
  if (!start_x || !start_y) {
    return false;
  }
  maybe_init_origin(pose.x, pose.y);
  if (++current_scan_stamp_ == 0) {
    hit_cell_scan_stamp_.fill(0);
    current_scan_stamp_ = 1;
  }
  return world_to_grid(pose.x, pose.y, start_x, start_y) != 0;
}

void Map::integrate_ray(
    int32_t x0,
    int32_t y0,
    int32_t x1,
    int32_t y1,
    std::vector<planning::GridCoord>* newly_occupied_cells,
    std::vector<uint8_t>* newly_occupied_mask) {
  int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
  int sx = (x0 < x1) ? 1 : -1;
  int dy = (y1 > y0) ? (y0 - y1) : (y1 - y0);
  int sy = (y0 < y1) ? 1 : -1;
  int err = dx + dy;

  int x = x0;
  int y = y0;
  while (true) {
    const int32_t idx = grid_index(x, y);
    const bool old_visited = visited_[idx] != 0;
    const bool old_confirmed = confirmed_[idx] != 0;
    visited_[idx] = 1;

    if (x == x1 && y == y1) {
      const int16_t count = clamp_cell_score(scan_count_[idx] + kHitIncrement);
      scan_count_[idx] = count;
      if (count >= kOccupiedThreshold) {
        confirmed_[idx] = 1;
      }
      maybe_record_cell_change(
          x,
          y,
          kMapSizeX,
          old_visited,
          old_confirmed,
          visited_[idx] != 0,
          confirmed_[idx] != 0,
          newly_occupied_cells,
          newly_occupied_mask);
      break;
    }

    const int16_t count = clamp_cell_score(scan_count_[idx] - kFreeDecrement);
    scan_count_[idx] = count;
    if (confirmed_[idx] && count <= kClearThreshold) {
      confirmed_[idx] = 0;
    }
    maybe_record_cell_change(
        x,
        y,
        kMapSizeX,
        old_visited,
        old_confirmed,
        visited_[idx] != 0,
        confirmed_[idx] != 0,
        newly_occupied_cells,
        newly_occupied_mask);

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

void Map::integrate_free_ray(
    int32_t x0,
    int32_t y0,
    int32_t x1,
    int32_t y1) {
  int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
  int sx = (x0 < x1) ? 1 : -1;
  int dy = (y1 > y0) ? (y0 - y1) : (y1 - y0);
  int sy = (y0 < y1) ? 1 : -1;
  int err = dx + dy;

  int x = x0;
  int y = y0;
  while (true) {
    const int32_t idx = grid_index(x, y);
    const bool old_visited = visited_[idx] != 0;
    const bool old_confirmed = confirmed_[idx] != 0;
    visited_[idx] = 1;
    const int16_t count = clamp_cell_score(scan_count_[idx] - kFreeDecrement);
    scan_count_[idx] = count;
    if (confirmed_[idx] && count <= kClearThreshold) {
      confirmed_[idx] = 0;
    }
    maybe_record_cell_change(
        x,
        y,
        kMapSizeX,
        old_visited,
        old_confirmed,
        visited_[idx] != 0,
        confirmed_[idx] != 0,
        nullptr,
        nullptr);
    if (x == x1 && y == y1) {
      break;
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

void Map::integrate_hit_world(
    int32_t start_x,
    int32_t start_y,
    const core::PoseSE2d& pose,
    double wx,
    double wy,
    std::vector<planning::GridCoord>* newly_occupied_cells,
    std::vector<uint8_t>* newly_occupied_mask) {
  const double min_range2 =
      static_cast<double>(kMinRange) * static_cast<double>(kMinRange);
  const double dx = wx - pose.x;
  const double dy = wy - pose.y;
  if ((dx * dx + dy * dy) < min_range2) {
    return;
  }

  int32_t end_x = 0;
  int32_t end_y = 0;
  if (!world_to_grid(wx, wy, &end_x, &end_y)) {
    return;
  }

  const int32_t end_idx = grid_index(end_x, end_y);
  if (hit_cell_scan_stamp_[end_idx] == current_scan_stamp_) {
    return;
  }
  hit_cell_scan_stamp_[end_idx] = current_scan_stamp_;
  integrate_ray(
      start_x,
      start_y,
      end_x,
      end_y,
      newly_occupied_cells,
      newly_occupied_mask);
}

void Map::integrate_free_world(
    int32_t start_x,
    int32_t start_y,
    double wx,
    double wy,
    std::vector<planning::GridCoord>* changed_cells,
    std::vector<uint8_t>* changed_mask) {
  int32_t end_x = 0;
  int32_t end_y = 0;
  if (!world_to_grid(wx, wy, &end_x, &end_y)) {
    return;
  }

  integrate_free_ray(start_x, start_y, end_x, end_y, changed_cells, changed_mask);
}

void Map::integrate_scan(
    const core::PoseSE2d& pose,
    int32_t point_count,
    int32_t points_in_world) {
  if (point_count <= 0) {
    return;
  }

  int32_t start_x = 0;
  int32_t start_y = 0;
  if (!begin_scan_integration(pose, &start_x, &start_y)) {
    return;
  }

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

    integrate_hit_world(start_x, start_y, pose, wx, wy);
  }
}

void Map::integrate_free_scan(const core::PoseSE2d& pose, int32_t free_point_count) {
  if (free_point_count <= 0) {
    return;
  }

  int32_t start_x = 0;
  int32_t start_y = 0;
  if (!begin_scan_integration(pose, &start_x, &start_y)) {
    return;
  }

  for (int32_t i = 0; i < free_point_count; ++i) {
    const int32_t base = i * 2;
    const float wx = free_points_[base + 0];
    const float wy = free_points_[base + 1];
    if (!is_finite(wx) || !is_finite(wy)) {
      continue;
    }
    integrate_free_world(start_x, start_y, static_cast<double>(wx), static_cast<double>(wy));
  }
}

void Map::draw_map(
    const core::PoseSE2d& pose,
    int32_t point_count,
    int32_t free_point_count) {
  if (point_count < 0) {
    point_count = 0;
  }
  if (point_count > kMaxMapPoints) {
    point_count = kMaxMapPoints;
  }
  if (free_point_count < 0) {
    free_point_count = 0;
  }
  if (free_point_count > kMaxFreeRays) {
    free_point_count = kMaxFreeRays;
  }

  const int32_t used_points =
      (point_count < points_count_) ? point_count : points_count_;
  const int32_t used_free =
      (free_point_count < free_points_count_) ? free_point_count : free_points_count_;

  if (used_points > 0) {
    integrate_scan(pose, used_points, points_in_world_);
  }
  if (used_free > 0) {
    integrate_free_scan(pose, used_free);
  }
}

}  // namespace mapping
