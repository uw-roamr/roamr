#include "planning/planner_bridge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <sstream>
#include <vector>

#include "core/telemetry.h"
#include "mapping/costmap.h"
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
std::atomic<uint64_t> g_goal_revision{0};
GoalChangeCallback g_goal_change_callback = nullptr;
std::mutex g_frontier_cache_mutex;
std::vector<GridCoord> g_persistent_frontier_goals;
std::mutex g_overlay_cache_mutex;
PlanningOverlay g_cached_overlay;
std::atomic<uint64_t> g_cached_overlay_revision{0};
std::mutex g_planned_path_mutex;
std::vector<core::Vector3d> g_planned_path_world;
uint64_t g_planned_path_revision = 0;
std::chrono::steady_clock::time_point g_last_auto_frontier_plan_time =
    std::chrono::steady_clock::time_point::min();

PlannerConfig build_planner_config() {
  return mapping::default_navigation_costmap_config();
}

FrontierExplorerConfig build_frontier_config() {
  FrontierExplorerConfig cfg;
  cfg.occupied_threshold = 50;
  cfg.allow_diagonal = true;
  cfg.prevent_corner_cutting = true;
  cfg.detection_inflation_radius_m = 0.04;
  cfg.inflation_radius_m = mapping::default_navigation_costmap_config().inflation_radius_m;
  cfg.simplify_path = true;
  cfg.snap_start_to_free = true;
  cfg.snap_goal_to_free = true;
  cfg.snap_search_radius_cells = 10;
  cfg.min_cluster_size = 4;
  cfg.goal_standoff_m = 0.18;
  cfg.min_standoff_path_progress_m = 0.10;
  return cfg;
}

PlannerConfig planner_config_from_frontier_config(const FrontierExplorerConfig& frontier_cfg) {
  PlannerConfig cfg;
  cfg.occupied_threshold = frontier_cfg.occupied_threshold;
  cfg.treat_unknown_as_occupied = true;
  cfg.allow_diagonal = frontier_cfg.allow_diagonal;
  cfg.prevent_corner_cutting = frontier_cfg.prevent_corner_cutting;
  cfg.inflation_radius_m = frontier_cfg.inflation_radius_m;
  cfg.simplify_path = frontier_cfg.simplify_path;
  cfg.snap_start_to_free = frontier_cfg.snap_start_to_free;
  cfg.snap_goal_to_free = frontier_cfg.snap_goal_to_free;
  cfg.snap_search_radius_cells = frontier_cfg.snap_search_radius_cells;
  cfg.max_expanded_nodes = frontier_cfg.max_expanded_nodes;
  return cfg;
}

double path_length_m(const std::vector<core::Vector3d>& path_world) {
  if (path_world.size() < 2) {
    return 0.0;
  }
  double length = 0.0;
  for (size_t i = 1; i < path_world.size(); ++i) {
    const double dx = path_world[i].x - path_world[i - 1].x;
    const double dy = path_world[i].y - path_world[i - 1].y;
    length += std::sqrt(dx * dx + dy * dy);
  }
  return length;
}

DStarLitePlanner g_planner(build_planner_config());

inline int32_t clampi(int32_t v, int32_t lo, int32_t hi) {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

bool is_path_segment_traversable(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy,
    const GridCoord& a,
    const GridCoord& b) {
  if (!map.in_bounds(a.x, a.y) || !map.in_bounds(b.x, b.y)) {
    return false;
  }
  return line_of_sight_free(map, cfg, occupancy, a, b);
}

bool is_path_grid_traversable(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy,
    const std::vector<GridCoord>& path_grid) {
  if (path_grid.empty()) {
    return false;
  }
  for (const GridCoord& cell : path_grid) {
    if (!map.in_bounds(cell.x, cell.y) ||
        is_cell_blocked(map, cfg, cell.x, cell.y, &occupancy)) {
      return false;
    }
  }
  for (size_t i = 1; i < path_grid.size(); ++i) {
    if (!is_path_segment_traversable(
            map, cfg, occupancy, path_grid[i - 1], path_grid[i])) {
      return false;
    }
  }
  return true;
}

void mark_inflated_cell(
    const GridMap2D& map,
    int32_t cx,
    int32_t cy,
    int32_t radius_cells,
    std::vector<uint8_t>* mask) {
  if (!mask || !map.in_bounds(cx, cy)) {
    return;
  }
  for (int32_t dy = -radius_cells; dy <= radius_cells; ++dy) {
    for (int32_t dx = -radius_cells; dx <= radius_cells; ++dx) {
      if ((dx * dx + dy * dy) > (radius_cells * radius_cells)) {
        continue;
      }
      const int32_t x = cx + dx;
      const int32_t y = cy + dy;
      if (!map.in_bounds(x, y)) {
        continue;
      }
      (*mask)[static_cast<size_t>(map.index(x, y))] = 1;
    }
  }
}

void mark_inflated_segment(
    const GridMap2D& map,
    const GridCoord& a,
    const GridCoord& b,
    int32_t radius_cells,
    std::vector<uint8_t>* mask) {
  int32_t x0 = a.x;
  int32_t y0 = a.y;
  const int32_t x1 = b.x;
  const int32_t y1 = b.y;
  const int32_t dx = std::abs(x1 - x0);
  const int32_t sx = x0 < x1 ? 1 : -1;
  const int32_t dy = -std::abs(y1 - y0);
  const int32_t sy = y0 < y1 ? 1 : -1;
  int32_t err = dx + dy;

  while (true) {
    mark_inflated_cell(map, x0, y0, radius_cells, mask);
    if (x0 == x1 && y0 == y1) {
      break;
    }
    const int32_t e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x0 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y0 += sy;
    }
  }
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

bool same_overlay_content(
    const PlanningOverlay& a,
    const PlanningOverlay& b) {
  return a.goal_enabled == b.goal_enabled &&
         a.goal_cell == b.goal_cell &&
         a.path_grid == b.path_grid &&
         a.frontier_candidates == b.frontier_candidates &&
         a.selected_frontier_cluster == b.selected_frontier_cluster &&
         a.selected_frontier_seed_enabled == b.selected_frontier_seed_enabled &&
         a.selected_frontier_seed == b.selected_frontier_seed;
}

void update_cached_path_world(const std::vector<core::Vector3d>& path_world) {
  std::lock_guard<std::mutex> lk(g_planned_path_mutex);
  if (same_path_world(g_planned_path_world, path_world)) {
    return;
  }
  g_planned_path_world = path_world;
  ++g_planned_path_revision;
}

void update_cached_overlay(const PlanningOverlay& overlay) {
  std::lock_guard<std::mutex> lk(g_overlay_cache_mutex);
  if (same_overlay_content(g_cached_overlay, overlay)) {
    g_cached_overlay.source_map_revision = overlay.source_map_revision;
    return;
  }
  g_cached_overlay = overlay;
  g_cached_overlay_revision.fetch_add(1, std::memory_order_acq_rel);
}

PlanningOverlay copy_cached_overlay() {
  std::lock_guard<std::mutex> lk(g_overlay_cache_mutex);
  return g_cached_overlay;
}

PlanningOverlay overlay_from_plan_result(
    uint64_t map_revision,
    const PlanResult& planned) {
  PlanningOverlay overlay;
  overlay.source_map_revision = map_revision;
  if (!planned.success || planned.path_grid.empty()) {
    update_cached_path_world({});
    update_cached_overlay(overlay);
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
  update_cached_overlay(overlay);
  return overlay;
}

PlanningOverlay overlay_from_frontier_result(
    uint64_t map_revision,
    const FrontierPlanResult& planned) {
  PlanningOverlay overlay;
  overlay.source_map_revision = map_revision;
  overlay.frontier_candidates = planned.frontier_cells;
  overlay.selected_frontier_cluster = planned.selected_cluster_cells;
  if (planned.success || !planned.selected_cluster_cells.empty()) {
    overlay.selected_frontier_seed_enabled = true;
    overlay.selected_frontier_seed = planned.selected_seed;
  }
  if (!planned.success || planned.path_grid.empty()) {
    update_cached_path_world({});
    update_cached_overlay(overlay);
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
  update_cached_overlay(overlay);
  return overlay;
}

}  // namespace

void set_goal_map_pixel(int32_t x, int32_t y) {
  GoalChangeCallback callback = nullptr;
  {
    std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
    g_planner_goal.active = true;
    g_planner_goal.x = x;
    g_planner_goal.y = y;
    g_goal_revision.fetch_add(1, std::memory_order_acq_rel);
    callback = g_goal_change_callback;
  }
  if (callback) {
    callback();
  }
}

void clear_goal() {
  GoalChangeCallback callback = nullptr;
  {
    std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
    if (g_planner_goal.active) {
      g_planner_goal.active = false;
      g_goal_revision.fetch_add(1, std::memory_order_acq_rel);
      callback = g_goal_change_callback;
    }
  }
  if (callback) {
    callback();
  }
}

uint64_t latest_goal_revision() {
  return g_goal_revision.load(std::memory_order_acquire);
}

bool has_active_goal() {
  std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
  return g_planner_goal.active;
}

void set_goal_change_callback(GoalChangeCallback callback) {
  std::lock_guard<std::mutex> lk(g_planner_goal_mutex);
  g_goal_change_callback = callback;
}

bool is_overlay_path_valid(
    const mapping::MapSnapshot& snapshot,
    const PlanningOverlay& overlay) {
  if (!snapshot.valid() || overlay.path_grid.empty()) {
    return false;
  }
  const PlannerConfig cfg = build_planner_config();
  mapping::InflatedCostmap costmap;
  if (!mapping::build_inflated_costmap(snapshot, cfg, &costmap)) {
    return false;
  }
  return is_path_grid_traversable(
      costmap.grid,
      costmap.config,
      costmap.inflated_occupancy,
      overlay.path_grid);
}

bool does_new_occupancy_intersect_overlay_path(
    const mapping::MapSnapshot& snapshot,
    const PlanningOverlay& overlay,
    const std::vector<GridCoord>& newly_occupied_cells) {
  if (!snapshot.valid() ||
      overlay.path_grid.empty() ||
      newly_occupied_cells.empty()) {
    return false;
  }
  const PlannerConfig cfg = build_planner_config();
  mapping::InflatedCostmap costmap;
  if (!mapping::build_inflated_costmap(snapshot, cfg, &costmap)) {
    return false;
  }
  const int32_t radius_cells = std::max<int32_t>(
      1,
      static_cast<int32_t>(
          std::ceil(cfg.inflation_radius_m / costmap.grid.resolution_m)) + 1);
  std::vector<uint8_t> path_mask(
      static_cast<size_t>(costmap.grid.width * costmap.grid.height),
      0);
  mark_inflated_cell(
      costmap.grid,
      overlay.path_grid.front().x,
      overlay.path_grid.front().y,
      radius_cells,
      &path_mask);
  for (size_t i = 1; i < overlay.path_grid.size(); ++i) {
    mark_inflated_segment(
        costmap.grid,
        overlay.path_grid[i - 1],
        overlay.path_grid[i],
        radius_cells,
        &path_mask);
  }
  for (const GridCoord& cell : newly_occupied_cells) {
    if (!costmap.grid.in_bounds(cell.x, cell.y)) {
      continue;
    }
    if (path_mask[static_cast<size_t>(costmap.grid.index(cell.x, cell.y))] != 0) {
      return true;
    }
  }
  return false;
}

void invalidate_current_plan() {
  {
    std::lock_guard<std::mutex> lk(g_planned_path_mutex);
    if (!g_planned_path_world.empty()) {
      g_planned_path_world.clear();
      ++g_planned_path_revision;
    }
  }
  update_cached_overlay(PlanningOverlay{});
  g_planner.invalidate();
}

void refresh_persistent_frontier_goals(
    const GridMap2D& planner_map,
    const core::Vector3d& start_world,
    const FrontierExplorerConfig& cfg) {
  GridCoord start_cell{};
  if (!world_to_grid(planner_map, start_world.x, start_world.y, &start_cell)) {
    std::lock_guard<std::mutex> lk(g_frontier_cache_mutex);
    g_persistent_frontier_goals.clear();
    return;
  }
  AStarPlanner planner(planner_config_from_frontier_config(cfg));
  std::vector<GridCoord> discovered =
      collect_frontier_goal_cells(planner_map, start_world, cfg);
  std::lock_guard<std::mutex> lk(g_frontier_cache_mutex);
  std::vector<GridCoord> merged;
  merged.reserve(g_persistent_frontier_goals.size() + discovered.size());
  for (const GridCoord& goal : g_persistent_frontier_goals) {
    if (!is_frontier_goal_candidate(planner_map, goal, cfg)) {
      continue;
    }
    const PlanResult planned = planner.plan_to_grid(planner_map, start_cell, goal);
    if (planned.success && !planned.path_grid.empty()) {
      merged.push_back(goal);
    }
  }
  for (const GridCoord& goal : discovered) {
    const auto it = std::find(merged.begin(), merged.end(), goal);
    if (it == merged.end()) {
      merged.push_back(goal);
    }
  }
  g_persistent_frontier_goals = std::move(merged);
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
      !mapping::load_snapshot_grid(snapshot, &planner_map)) {
    wasm_log_line("[planning] invalid snapshot or planner grid");
    update_cached_path_world({});
    update_cached_overlay(overlay);
    return overlay;
  }
  if (!world_to_grid(
          planner_map,
          snapshot.pose.x,
          snapshot.pose.y,
          &start_cell)) {
    std::ostringstream start_log;
    start_log << "[planning] start pose outside grid pose=("
              << snapshot.pose.x << "," << snapshot.pose.y << "," << snapshot.pose.theta
              << ")";
    wasm_log_line(start_log.str());
    update_cached_path_world({});
    update_cached_overlay(overlay);
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
      update_cached_overlay(overlay);
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
    update_cached_overlay(overlay);
    return overlay;
  }

  const auto now = std::chrono::steady_clock::now();
  const double elapsed_sec = std::chrono::duration<double>(
      now - g_last_auto_frontier_plan_time).count();
  if (g_last_auto_frontier_plan_time != std::chrono::steady_clock::time_point::min() &&
      elapsed_sec < kAutoFrontierReplanIntervalSec) {
    PlanningOverlay cached = copy_cached_overlay();
    if (cached.source_map_revision != 0) {
      cached.source_map_revision = snapshot.map_revision;
    }
    return cached;
  }
  g_last_auto_frontier_plan_time = now;

  const FrontierExplorerConfig frontier_cfg = build_frontier_config();
  const FrontierPlanResult planned = planning::simplified::plan_to_largest_frontier(
      planner_map,
      core::Vector3d{snapshot.pose.x, snapshot.pose.y, snapshot.pose.theta},
      frontier_cfg);
  std::ostringstream frontier_log;
  frontier_log << "[planning] frontier result success=" << (planned.success ? 1 : 0)
               << " start=(" << start_cell.x << "," << start_cell.y << ")"
               << " frontier_cells=" << planned.frontier_cell_count
               << " clusters=" << planned.cluster_count
               << " selected_cluster_size=" << planned.selected_cluster_size
               << " path_length_m=" << planned.selected_path_length_m
               << " goal_standoff_m=" << planned.selected_goal_standoff_m
               << " heading_delta_rad=" << planned.selected_heading_delta_rad
               << " selected_seed=(" << planned.selected_seed.x << ","
               << planned.selected_seed.y << ")"
               << " message=" << planned.message;
  wasm_log_line(frontier_log.str());
  overlay = overlay_from_frontier_result(snapshot.map_revision, planned);
  update_cached_overlay(overlay);
  return overlay;
}

uint64_t copy_latest_plan_world(std::vector<core::Vector3d>* out_path) {
  std::lock_guard<std::mutex> lk(g_planned_path_mutex);
  if (out_path) {
    *out_path = g_planned_path_world;
  }
  return g_planned_path_revision;
}

uint64_t latest_overlay_revision() {
  return g_cached_overlay_revision.load(std::memory_order_acquire);
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
