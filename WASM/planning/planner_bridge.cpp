#include "planning/planner_bridge.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <mutex>
#include <sstream>
#include <vector>

#include "core/telemetry.h"
#include "planning/frontier_explorer.h"
#include "planning/planner.h"

namespace planning::bridge {
namespace {

constexpr int32_t kRenderWidthDefault = 256;   // keep in sync with mapping/map_update.cpp
constexpr int32_t kRenderHeightDefault = 256;  // keep in sync with mapping/map_update.cpp
constexpr int32_t kMaxPlannedPathCells = 4096; // keep in sync with mapping/map.cpp
constexpr bool kEnableAutoFrontierExploration = true;
constexpr double kAutoFrontierReplanIntervalSec = 0.75;

struct PlannerGoalPixel {
  bool active = false;
  int32_t x = 0;
  int32_t y = 0;
};

std::mutex g_planner_goal_mutex;
PlannerGoalPixel g_planner_goal;
std::mutex g_planned_path_mutex;
std::vector<core::Vector3d> g_planned_path_world;
uint64_t g_planned_path_revision = 0;
std::chrono::steady_clock::time_point g_last_auto_frontier_plan_time =
    std::chrono::steady_clock::time_point::min();

PlannerConfig build_planner_config() {
  PlannerConfig cfg;
  cfg.occupied_threshold = 50;
  cfg.treat_unknown_as_occupied = true;
  cfg.allow_diagonal = true;
  cfg.prevent_corner_cutting = true;
  cfg.inflation_radius_m = 0.20;
  cfg.simplify_path = true;
  cfg.snap_start_to_free = true;
  cfg.snap_goal_to_free = true;
  cfg.snap_search_radius_cells = 10;
  return cfg;
}

FrontierExplorerConfig build_frontier_config() {
  FrontierExplorerConfig cfg;
  cfg.occupied_threshold = 50;
  cfg.allow_diagonal = true;
  cfg.prevent_corner_cutting = true;
  cfg.inflation_radius_m = 0.20;
  cfg.simplify_path = true;
  cfg.snap_start_to_free = true;
  cfg.snap_goal_to_free = true;
  cfg.snap_search_radius_cells = 10;
  cfg.min_cluster_size = 4;
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

bool load_planner_grid(const mapping::MapSnapshot& snapshot, GridMap2D* out_map) {
  if (!out_map) {
    return false;
  }
  const mapping::OccupancyGridMetadata& meta = snapshot.meta;
  if (meta.width <= 0 || meta.height <= 0 || meta.resolution_m <= 0.0) {
    return false;
  }
  out_map->width = meta.width;
  out_map->height = meta.height;
  out_map->resolution_m = meta.resolution_m;
  out_map->origin_x_m = meta.origin_x_m;
  out_map->origin_y_m = meta.origin_y_m;
  out_map->data = snapshot.occupancy;
  if (out_map->data.size() != static_cast<size_t>(meta.width * meta.height)) {
    return false;
  }
  return true;
}

bool render_pixel_to_map_cell(
    const mapping::MapSnapshot& snapshot,
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

  const mapping::OccupancyGridMetadata& meta = snapshot.meta;
  if (meta.width <= 0 || meta.height <= 0) {
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

bool same_path_world(
    const std::vector<core::Vector3d>& a,
    const std::vector<core::Vector3d>& b) {
  if (a.size() != b.size()) {
    return false;
  }
  constexpr double kEps = 1e-6;
  for (size_t i = 0; i < a.size(); ++i) {
    if (std::abs(a[i].x - b[i].x) > kEps ||
        std::abs(a[i].y - b[i].y) > kEps ||
        std::abs(a[i].z - b[i].z) > kEps) {
      return false;
    }
  }
  return true;
}

void update_cached_path_world(const std::vector<core::Vector3d>& path_world) {
  std::lock_guard<std::mutex> lk(g_planned_path_mutex);
  if (same_path_world(g_planned_path_world, path_world)) {
    return;
  }
  g_planned_path_world = path_world;
  ++g_planned_path_revision;
}

PlanningOverlay overlay_from_plan_result(
    uint64_t map_revision,
    const PlanResult& planned) {
  PlanningOverlay overlay;
  overlay.source_map_revision = map_revision;
  if (!planned.success || planned.path_grid.empty()) {
    update_cached_path_world({});
    return overlay;
  }

  const int32_t limit = std::min<int32_t>(
      static_cast<int32_t>(planned.path_grid.size()),
      kMaxPlannedPathCells);
  overlay.goal_enabled = true;
  overlay.goal_cell = planned.path_grid.back();
  overlay.path_grid.assign(
      planned.path_grid.begin(),
      planned.path_grid.begin() + limit);
  update_cached_path_world(planned.path_world);
  return overlay;
}

PlanningOverlay overlay_from_frontier_result(
    uint64_t map_revision,
    const FrontierPlanResult& planned) {
  PlanningOverlay overlay;
  overlay.source_map_revision = map_revision;
  if (!planned.success || planned.path_grid.empty()) {
    update_cached_path_world({});
    return overlay;
  }

  overlay.goal_enabled = true;
  overlay.goal_cell = planned.goal_cell;
  const int32_t limit = std::min<int32_t>(
      static_cast<int32_t>(planned.path_grid.size()),
      kMaxPlannedPathCells);
  overlay.path_grid.assign(
      planned.path_grid.begin(),
      planned.path_grid.begin() + limit);
  update_cached_path_world(planned.path_world);
  return overlay;
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

PlanningOverlay update_plan_overlay(
    const mapping::MapSnapshot& snapshot,
    int32_t render_width,
    int32_t render_height) {
  PlanningOverlay overlay;
  overlay.source_map_revision = snapshot.map_revision;

  PlannerGoalPixel goal{};
  {
    std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
    goal = g_planner_goal;
  }

  GridMap2D planner_map;
  GridCoord start_cell{};
  if (!snapshot.valid() ||
      !load_planner_grid(snapshot, &planner_map) ||
      !world_to_grid(
          planner_map,
          snapshot.pose.x,
          snapshot.pose.y,
          &start_cell)) {
    update_cached_path_world({});
    return overlay;
  }

  if (goal.active) {
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
            snapshot,
            goal_x,
            goal_y,
            render_width,
            render_height,
            &goal_cell)) {
      update_cached_path_world({});
      return overlay;
    }

    const PlanResult planned = g_planner.plan_to_grid(planner_map, start_cell, goal_cell);
    std::ostringstream plan_log;
    plan_log << "[planning] direct goal result success=" << (planned.success ? 1 : 0)
             << " start=(" << start_cell.x << "," << start_cell.y << ")"
             << " goal=(" << goal_cell.x << "," << goal_cell.y << ")"
             << " path_cells=" << planned.path_grid.size()
             << " message=" << planned.message;
    wasm_log_line(plan_log.str());
    return overlay_from_plan_result(snapshot.map_revision, planned);
  }

  if (!kEnableAutoFrontierExploration) {
    update_cached_path_world({});
    return overlay;
  }

  const auto now = std::chrono::steady_clock::now();
  const double elapsed_sec = std::chrono::duration<double>(
      now - g_last_auto_frontier_plan_time).count();
  if (g_last_auto_frontier_plan_time != std::chrono::steady_clock::time_point::min() &&
      elapsed_sec < kAutoFrontierReplanIntervalSec) {
    return overlay;
  }
  g_last_auto_frontier_plan_time = now;

  const FrontierPlanResult planned = plan_to_nearest_frontier(
      planner_map,
      core::Vector3d{snapshot.pose.x, snapshot.pose.y, 0.0},
      build_frontier_config());
  return overlay_from_frontier_result(snapshot.map_revision, planned);
}

uint64_t copy_latest_plan_world(std::vector<core::Vector3d>* out_path) {
  std::lock_guard<std::mutex> lk(g_planned_path_mutex);
  if (out_path) {
    *out_path = g_planned_path_world;
  }
  return g_planned_path_revision;
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
