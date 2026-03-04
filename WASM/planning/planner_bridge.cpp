#include "planning/planner_bridge.h"

#include <algorithm>
#include <mutex>

#include "mapping/map_api.h"
#include "planning/planner.h"

namespace planning::bridge {
namespace {

constexpr int32_t kRenderWidthDefault = 256;   // keep in sync with mapping/map_update.cpp
constexpr int32_t kRenderHeightDefault = 256;  // keep in sync with mapping/map_update.cpp
constexpr int32_t kMaxPlannedPathCells = 4096; // keep in sync with mapping/map.cpp

struct PlannerGoalPixel {
  bool active = false;
  int32_t x = 0;
  int32_t y = 0;
};

std::mutex g_planner_goal_mutex;
PlannerGoalPixel g_planner_goal;

PlannerConfig build_planner_config() {
  PlannerConfig cfg;
  cfg.occupied_threshold = 50;
  cfg.treat_unknown_as_occupied = true;
  cfg.allow_diagonal = true;
  cfg.prevent_corner_cutting = true;
  cfg.inflation_radius_m = 0.0;
  cfg.simplify_path = true;
  cfg.snap_start_to_free = true;
  cfg.snap_goal_to_free = true;
  cfg.snap_search_radius_cells = 10;
  return cfg;
}

AStarPlanner g_planner(build_planner_config());

inline int32_t clampi(int32_t v, int32_t lo, int32_t hi) {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

bool load_planner_grid(GridMap2D* out_map) {
  if (!out_map) {
    return false;
  }
  mapping::OccupancyGridMeta meta{};
  if (!mapping::get_occupancy_meta(&meta)) {
    return false;
  }
  if (meta.width <= 0 || meta.height <= 0 || meta.resolution_m <= 0.0) {
    return false;
  }
  out_map->width = meta.width;
  out_map->height = meta.height;
  out_map->resolution_m = meta.resolution_m;
  out_map->origin_x_m = meta.origin_x_m;
  out_map->origin_y_m = meta.origin_y_m;
  out_map->data.assign(
      static_cast<size_t>(meta.width * meta.height),
      static_cast<int8_t>(-1));
  const int32_t copied =
      mapping::get_occupancy_grid(
          out_map->data.data(),
          static_cast<int32_t>(out_map->data.size()));
  if (copied != meta.width * meta.height) {
    return false;
  }
  return true;
}

bool render_pixel_to_map_cell(
    int32_t pixel_x,
    int32_t pixel_y,
    int32_t render_width,
    int32_t render_height,
    GridCoord* out_cell) {
  if (!out_cell || render_width <= 0 || render_height <= 0) {
    return false;
  }
  if (pixel_x < 0 || pixel_x >= render_width || pixel_y < 0 ||
      pixel_y >= render_height) {
    return false;
  }

  mapping::OccupancyGridMeta meta{};
  if (!mapping::get_occupancy_meta(&meta) || meta.width <= 0 || meta.height <= 0) {
    return false;
  }
  const double scale_x = static_cast<double>(render_width) / meta.width;
  const double scale_y = static_cast<double>(render_height) / meta.height;
  const double scale = std::min(scale_x, scale_y);
  if (scale <= 0.0) {
    return false;
  }
  const double map_w = meta.width * scale;
  const double map_h = meta.height * scale;
  const double off_x = (render_width - map_w) * 0.5;
  const double off_y = (render_height - map_h) * 0.5;
  const double mx = (static_cast<double>(pixel_x) - off_x) / scale;
  const double my = (static_cast<double>(pixel_y) - off_y) / scale;
  if (mx < 0.0 || mx >= static_cast<double>(meta.width) ||
      my < 0.0 || my >= static_cast<double>(meta.height)) {
    return false;
  }
  const int32_t gx = static_cast<int32_t>(mx);
  const int32_t gy = meta.height - 1 - static_cast<int32_t>(my);
  if (gx < 0 || gx >= meta.width || gy < 0 || gy >= meta.height) {
    return false;
  }
  *out_cell = GridCoord{gx, gy};
  return true;
}

}  // namespace

void set_goal_map_pixel(int32_t x, int32_t y) {
  std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
  g_planner_goal.active = true;
  g_planner_goal.x = x;
  g_planner_goal.y = y;
}

void clear_goal() {
  std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
  g_planner_goal.active = false;
}

void update_plan_overlay(
    const core::Vector3d& robot_translation_world,
    int32_t render_width,
    int32_t render_height) {
  PlannerGoalPixel goal{};
  {
    std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
    goal = g_planner_goal;
  }

  if (!goal.active) {
    mapping::clear_planned_path();
    return;
  }

  if (render_width <= 0) {
    render_width = kRenderWidthDefault;
  }
  if (render_height <= 0) {
    render_height = kRenderHeightDefault;
  }

  GridCoord goal_cell{};
  const int32_t goal_x = clampi(goal.x, 0, render_width - 1);
  const int32_t goal_y = clampi(goal.y, 0, render_height - 1);
  if (!render_pixel_to_map_cell(
          goal_x,
          goal_y,
          render_width,
          render_height,
          &goal_cell)) {
    mapping::clear_planned_path();
    return;
  }

  mapping::clear_planned_path();
  mapping::set_planned_goal_cell(goal_cell.x, goal_cell.y, 1);

  GridMap2D planner_map;
  GridCoord start_cell{};
  if (!load_planner_grid(&planner_map) ||
      !world_to_grid(
          planner_map,
          robot_translation_world.x,
          robot_translation_world.y,
          &start_cell)) {
    return;
  }

  const PlanResult planned = g_planner.plan_to_grid(planner_map, start_cell, goal_cell);
  if (!planned.success || planned.path_grid.empty()) {
    return;
  }

  const int32_t limit = std::min<int32_t>(
      static_cast<int32_t>(planned.path_grid.size()),
      kMaxPlannedPathCells);
  for (int32_t i = 0; i < limit; ++i) {
    const GridCoord& c = planned.path_grid[static_cast<size_t>(i)];
    mapping::set_planned_path_cell(i, c.x, c.y);
  }
}

}  // namespace planning::bridge

extern "C" __attribute__((export_name("set_planner_goal_map_pixel")))
void set_planner_goal_map_pixel(int32_t x, int32_t y) {
  planning::bridge::set_goal_map_pixel(x, y);
}

extern "C" __attribute__((export_name("clear_planner_goal_map_pixel")))
void clear_planner_goal_map_pixel() {
  planning::bridge::clear_goal();
}

