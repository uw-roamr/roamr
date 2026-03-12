#include "mapping/visualization.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "mapping/costmap.h"
#include "mapping/map.h"

namespace mapping {
namespace visualization {

namespace {

constexpr int32_t kMaxPixels = Map::kMaxImageWidth * Map::kMaxImageHeight;
constexpr int32_t kPoseLineLength = 10;
constexpr bool kEmitCompositeMapFrame = false;

static std::array<uint8_t, kMaxPixels * 4> s_image_buf{};
static std::array<uint8_t, kMaxPixels * 4> s_base_layer_buf{};
static std::array<uint8_t, kMaxPixels * 4> s_planning_layer_buf{};
static std::array<uint8_t, kMaxPixels * 4> s_frontiers_layer_buf{};
static int32_t s_cur_w = 0;
static int32_t s_cur_h = 0;
static uint64_t s_cached_static_map_revision = 0;
static uint64_t s_cached_static_overlay_revision = 0;
static int32_t s_cached_static_w = 0;
static int32_t s_cached_static_h = 0;
static bool s_have_cached_static_layers = false;

inline void clear_image(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  const int32_t pixel_count = s_cur_w * s_cur_h;
  for (int32_t i = 0; i < pixel_count; ++i) {
    const int32_t off = i * 4;
    s_image_buf[off + 0] = r;
    s_image_buf[off + 1] = g;
    s_image_buf[off + 2] = b;
    s_image_buf[off + 3] = a;
  }
}

inline void paint_pixel(
    int32_t x,
    int32_t y,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a) {
  if (x < 0 || x >= s_cur_w || y < 0 || y >= s_cur_h) {
    return;
  }
  const int32_t off = (y * s_cur_w + x) * 4;
  s_image_buf[off + 0] = r;
  s_image_buf[off + 1] = g;
  s_image_buf[off + 2] = b;
  s_image_buf[off + 3] = a;
}

void draw_line(
    int32_t x0,
    int32_t y0,
    int32_t x1,
    int32_t y1,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a) {
  int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
  int sx = (x0 < x1) ? 1 : -1;
  int dy = -((y1 > y0) ? (y1 - y0) : (y0 - y1));
  int sy = (y0 < y1) ? 1 : -1;
  int err = dx + dy;
  int x = x0;
  int y = y0;
  for (;;) {
    paint_pixel(x, y, r, g, b, a);
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

void draw_map_pixels(
    const MapSnapshot& snapshot,
    float scale,
    float off_x,
    float off_y) {
  for (int32_t py = 0; py < s_cur_h; ++py) {
    for (int32_t px = 0; px < s_cur_w; ++px) {
      const int32_t gx = static_cast<int32_t>(
          (static_cast<float>(px) - off_x) / scale);
      const int32_t gy = snapshot.meta.height - 1 - static_cast<int32_t>(
          (static_cast<float>(py) - off_y) / scale);

      uint8_t r = 128;
      uint8_t g = 128;
      uint8_t b = 128;
      if (gx >= 0 && gx < snapshot.meta.width &&
          gy >= 0 && gy < snapshot.meta.height) {
        const int32_t idx = gx + gy * snapshot.meta.width;
        const int8_t occ = snapshot.occupancy[static_cast<size_t>(idx)];
        if (occ >= 0) {
          r = occ >= 50 ? 255 : 0;
          g = r;
          b = r;
        }
      }
      paint_pixel(px, py, r, g, b, 255);
    }
  }
}

void draw_inflation_pixels(
    const MapSnapshot& snapshot,
    const InflatedCostmap& costmap,
    float scale,
    float off_x,
    float off_y,
    uint8_t alpha) {
  for (int32_t py = 0; py < s_cur_h; ++py) {
    for (int32_t px = 0; px < s_cur_w; ++px) {
      const int32_t gx = static_cast<int32_t>(
          (static_cast<float>(px) - off_x) / scale);
      const int32_t gy = snapshot.meta.height - 1 - static_cast<int32_t>(
          (static_cast<float>(py) - off_y) / scale);
      if (gx < 0 || gx >= snapshot.meta.width ||
          gy < 0 || gy >= snapshot.meta.height) {
        continue;
      }
      if (!costmap.is_inflated_blocked(gx, gy) || costmap.is_source_occupied(gx, gy)) {
        continue;
      }
      paint_pixel(px, py, 210, 140, 140, alpha);
    }
  }
}

void draw_pose(
    const MapSnapshot& snapshot,
    float scale,
    float off_x,
    float off_y) {
  const int32_t gx = static_cast<int32_t>(
      std::floor((snapshot.pose.x - snapshot.meta.origin_x_m) / snapshot.meta.resolution_m));
  const int32_t gy = static_cast<int32_t>(
      std::floor((snapshot.pose.y - snapshot.meta.origin_y_m) / snapshot.meta.resolution_m));
  if (gx < 0 || gx >= snapshot.meta.width ||
      gy < 0 || gy >= snapshot.meta.height) {
    return;
  }

  int32_t ppx = 0;
  int32_t ppy = 0;
  if (!snapshot_grid_to_pixel(
          snapshot.meta,
          gx,
          gy,
          s_cur_w,
          s_cur_h,
          scale,
          off_x,
          off_y,
          &ppx,
          &ppy)) {
    return;
  }

  const double c = std::cos(snapshot.pose.theta);
  const double s = std::sin(snapshot.pose.theta);
  const int32_t fwd_x1 = ppx + static_cast<int32_t>(c * kPoseLineLength);
  const int32_t fwd_y1 = ppy + static_cast<int32_t>(-s * kPoseLineLength);
  const int32_t left_x1 = ppx + static_cast<int32_t>(-s * kPoseLineLength);
  const int32_t left_y1 = ppy + static_cast<int32_t>(-c * kPoseLineLength);

  draw_line(ppx, ppy, fwd_x1, fwd_y1, 255, 0, 0, 255);
  draw_line(ppx, ppy, left_x1, left_y1, 0, 255, 0, 255);
}

void draw_pose_trail(
    const MapSnapshot& snapshot,
    const PoseTrailState& pose_trail,
    float scale,
    float off_x,
    float off_y) {
  for (size_t i = 1; i < pose_trail.poses.size(); ++i) {
    const core::PoseSE2d& a = pose_trail.poses[i - 1];
    const core::PoseSE2d& b = pose_trail.poses[i];
    const int32_t ax = static_cast<int32_t>(
        std::floor((a.x - snapshot.meta.origin_x_m) / snapshot.meta.resolution_m));
    const int32_t ay = static_cast<int32_t>(
        std::floor((a.y - snapshot.meta.origin_y_m) / snapshot.meta.resolution_m));
    const int32_t bx = static_cast<int32_t>(
        std::floor((b.x - snapshot.meta.origin_x_m) / snapshot.meta.resolution_m));
    const int32_t by = static_cast<int32_t>(
        std::floor((b.y - snapshot.meta.origin_y_m) / snapshot.meta.resolution_m));

    int32_t px0 = 0;
    int32_t py0 = 0;
    int32_t px1 = 0;
    int32_t py1 = 0;
    if (!snapshot_grid_to_pixel(
            snapshot.meta, ax, ay, s_cur_w, s_cur_h, scale, off_x, off_y, &px0, &py0) ||
        !snapshot_grid_to_pixel(
            snapshot.meta, bx, by, s_cur_w, s_cur_h, scale, off_x, off_y, &px1, &py1)) {
      continue;
    }
    draw_line(px0, py0, px1, py1, 120, 90, 255, 255);
  }
}

void draw_path(
    const MapSnapshot& snapshot,
    const planning::bridge::PlanningOverlay& overlay,
    float scale,
    float off_x,
    float off_y,
    uint8_t alpha) {
  int32_t prev_x = 0;
  int32_t prev_y = 0;
  bool have_prev = false;
  for (const planning::GridCoord& cell : overlay.path_grid) {
    int32_t ppx = 0;
    int32_t ppy = 0;
    if (!snapshot_grid_to_pixel(
            snapshot.meta,
            cell.x,
            cell.y,
            s_cur_w,
            s_cur_h,
            scale,
            off_x,
            off_y,
            &ppx,
            &ppy)) {
      continue;
    }
    if (have_prev) {
      draw_line(prev_x, prev_y, ppx, ppy, 0, 150, 255, alpha);
    }
    paint_pixel(ppx, ppy, 0, 150, 255, alpha);
    prev_x = ppx;
    prev_y = ppy;
    have_prev = true;
  }
}

void draw_goal(
    const MapSnapshot& snapshot,
    const planning::bridge::PlanningOverlay& overlay,
    float scale,
    float off_x,
    float off_y,
    uint8_t alpha) {
  if (!overlay.goal_enabled) {
    return;
  }
  int32_t ppx = 0;
  int32_t ppy = 0;
  if (!snapshot_grid_to_pixel(
          snapshot.meta,
          overlay.goal_cell.x,
          overlay.goal_cell.y,
          s_cur_w,
          s_cur_h,
          scale,
          off_x,
          off_y,
          &ppx,
          &ppy)) {
    return;
  }
  for (int32_t dy = -2; dy <= 2; ++dy) {
    for (int32_t dx = -2; dx <= 2; ++dx) {
      paint_pixel(ppx + dx, ppy + dy, 255, 200, 0, alpha);
    }
  }
}

void draw_frontiers(
    const MapSnapshot& snapshot,
    const planning::bridge::PlanningOverlay& overlay,
    float scale,
    float off_x,
    float off_y,
    uint8_t alpha) {
  for (const planning::GridCoord& cell : overlay.frontier_candidates) {
    int32_t ppx = 0;
    int32_t ppy = 0;
    if (!snapshot_grid_to_pixel(
            snapshot.meta,
            cell.x,
            cell.y,
            s_cur_w,
            s_cur_h,
            scale,
            off_x,
            off_y,
            &ppx,
            &ppy)) {
      continue;
    }
    paint_pixel(ppx, ppy, 0, 255, 180, alpha);
  }

  for (const planning::GridCoord& cell : overlay.selected_frontier_cluster) {
    int32_t ppx = 0;
    int32_t ppy = 0;
    if (!snapshot_grid_to_pixel(
            snapshot.meta,
            cell.x,
            cell.y,
            s_cur_w,
            s_cur_h,
            scale,
            off_x,
            off_y,
            &ppx,
            &ppy)) {
      continue;
    }
    paint_pixel(ppx, ppy, 255, 0, 220, alpha);
  }

  if (!overlay.selected_frontier_seed_enabled) {
    return;
  }
  int32_t ppx = 0;
  int32_t ppy = 0;
  if (!snapshot_grid_to_pixel(
          snapshot.meta,
          overlay.selected_frontier_seed.x,
          overlay.selected_frontier_seed.y,
          s_cur_w,
          s_cur_h,
          scale,
          off_x,
          off_y,
          &ppx,
          &ppy)) {
    return;
  }
  for (int32_t dy = -1; dy <= 1; ++dy) {
    for (int32_t dx = -1; dx <= 1; ++dx) {
      paint_pixel(ppx + dx, ppy + dy, 255, 80, 0, alpha);
    }
  }
}

void cache_static_layers(
    const MapSnapshot& snapshot,
    const planning::bridge::PlanningOverlay& overlay,
    const InflatedCostmap* costmap_ptr,
    float scale,
    float off_x,
    float off_y,
    uint64_t overlay_revision) {
  clear_image(128, 128, 128, 255);
  draw_map_pixels(snapshot, scale, off_x, off_y);
  std::memcpy(
      s_base_layer_buf.data(),
      s_image_buf.data(),
      static_cast<size_t>(s_cur_w * s_cur_h * 4));

  clear_image(0, 0, 0, 0);
  if (costmap_ptr) {
    draw_inflation_pixels(snapshot, *costmap_ptr, scale, off_x, off_y, 160);
  }
  draw_path(snapshot, overlay, scale, off_x, off_y, 255);
  draw_goal(snapshot, overlay, scale, off_x, off_y, 255);
  std::memcpy(
      s_planning_layer_buf.data(),
      s_image_buf.data(),
      static_cast<size_t>(s_cur_w * s_cur_h * 4));

  clear_image(0, 0, 0, 0);
  draw_frontiers(snapshot, overlay, scale, off_x, off_y, 255);
  std::memcpy(
      s_frontiers_layer_buf.data(),
      s_image_buf.data(),
      static_cast<size_t>(s_cur_w * s_cur_h * 4));

  s_cached_static_map_revision = snapshot.map_revision;
  s_cached_static_overlay_revision = overlay_revision;
  s_cached_static_w = s_cur_w;
  s_cached_static_h = s_cur_h;
  s_have_cached_static_layers = true;
}

void emit_frame(
    MapRenderLayerId layer_id,
    double timestamp,
    MapImage& out_frame) {
  out_frame.timestamp = timestamp;
  out_frame.width = s_cur_w;
  out_frame.height = s_cur_h;
  out_frame.channels = 4;
  out_frame.data_ptr = static_cast<uint32_t>(
      reinterpret_cast<uintptr_t>(s_image_buf.data()));
  out_frame.data_size = static_cast<int32_t>(s_cur_w * s_cur_h * 4);
  out_frame.layer_id = static_cast<int32_t>(layer_id);
  rerun_log_map_frame(&out_frame);
}

void emit_cached_frame(
    const std::array<uint8_t, kMaxPixels * 4>& buffer,
    MapRenderLayerId layer_id,
    double timestamp,
    MapImage& out_frame) {
  out_frame.timestamp = timestamp;
  out_frame.width = s_cur_w;
  out_frame.height = s_cur_h;
  out_frame.channels = 4;
  out_frame.data_ptr = static_cast<uint32_t>(
      reinterpret_cast<uintptr_t>(buffer.data()));
  out_frame.data_size = static_cast<int32_t>(s_cur_w * s_cur_h * 4);
  out_frame.layer_id = static_cast<int32_t>(layer_id);
  rerun_log_map_frame(&out_frame);
}

}  // namespace

void render_map_frame(
    const MapSnapshot& snapshot,
    const PoseTrailState& pose_trail,
    const planning::bridge::PlanningOverlay& overlay,
    uint64_t overlay_revision,
    int32_t width,
    int32_t height,
    MapImage& out_frame) {
  if (!snapshot.valid()) {
    return;
  }

  if (width <= 0) {
    width = 256;
  }
  if (height <= 0) {
    height = 256;
  }
  if (width > Map::kMaxImageWidth) {
    width = Map::kMaxImageWidth;
  }
  if (height > Map::kMaxImageHeight) {
    height = Map::kMaxImageHeight;
  }
  s_cur_w = width;
  s_cur_h = height;

  float scale = 1.0f;
  float off_x = 0.0f;
  float off_y = 0.0f;
  compute_snapshot_viewport(snapshot.meta, s_cur_w, s_cur_h, &scale, &off_x, &off_y);

  const bool static_layers_changed =
      !s_have_cached_static_layers ||
      s_cached_static_w != s_cur_w ||
      s_cached_static_h != s_cur_h ||
      s_cached_static_map_revision != snapshot.map_revision ||
      s_cached_static_overlay_revision != overlay_revision;
  if (static_layers_changed) {
    InflatedCostmap costmap;
    const bool have_costmap = build_inflated_costmap(
        snapshot,
        default_navigation_costmap_config(),
        &costmap);
    cache_static_layers(
        snapshot,
        overlay,
        have_costmap ? &costmap : nullptr,
        scale,
        off_x,
        off_y,
        overlay_revision);
    emit_cached_frame(s_base_layer_buf, MapRenderLayerId::Base, snapshot.timestamp, out_frame);
    emit_cached_frame(s_planning_layer_buf, MapRenderLayerId::Planning, snapshot.timestamp, out_frame);
    emit_cached_frame(s_frontiers_layer_buf, MapRenderLayerId::Frontiers, snapshot.timestamp, out_frame);
  }

  clear_image(0, 0, 0, 0);
  draw_pose_trail(snapshot, pose_trail, scale, off_x, off_y);
  draw_pose(snapshot, scale, off_x, off_y);
  emit_frame(MapRenderLayerId::Odometry, snapshot.timestamp, out_frame);

  if (!kEmitCompositeMapFrame) {
    return;
  }

  std::memcpy(
      s_image_buf.data(),
      s_base_layer_buf.data(),
      static_cast<size_t>(s_cur_w * s_cur_h * 4));
  for (int32_t i = 0; i < s_cur_w * s_cur_h; ++i) {
    const int32_t off = i * 4;
    if (s_planning_layer_buf[off + 3] > 0) {
      s_image_buf[off + 0] = s_planning_layer_buf[off + 0];
      s_image_buf[off + 1] = s_planning_layer_buf[off + 1];
      s_image_buf[off + 2] = s_planning_layer_buf[off + 2];
      s_image_buf[off + 3] = 255;
    }
    if (s_frontiers_layer_buf[off + 3] > 0) {
      s_image_buf[off + 0] = s_frontiers_layer_buf[off + 0];
      s_image_buf[off + 1] = s_frontiers_layer_buf[off + 1];
      s_image_buf[off + 2] = s_frontiers_layer_buf[off + 2];
      s_image_buf[off + 3] = 255;
    }
  }
  draw_pose_trail(snapshot, pose_trail, scale, off_x, off_y);
  draw_pose(snapshot, scale, off_x, off_y);
  emit_frame(MapRenderLayerId::Composite, snapshot.timestamp, out_frame);
}

}  // namespace visualization
}  // namespace mapping
