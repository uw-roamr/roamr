#include "planning/frontier_explorer.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <queue>
#include <functional>
#include <queue>
#include <sstream>
#include <vector>

#include "core/telemetry.h"

namespace planning::simplified {
namespace {

PlannerConfig build_simple_planner_config(const FrontierExplorerConfig& cfg) {
  PlannerConfig planner_cfg;
  planner_cfg.occupied_threshold = cfg.occupied_threshold;
  planner_cfg.treat_unknown_as_occupied = true;
  planner_cfg.allow_diagonal = true;
  planner_cfg.prevent_corner_cutting = true;
  planner_cfg.inflation_radius_m = cfg.inflation_radius_m;
  planner_cfg.simplify_path = cfg.simplify_path;
  planner_cfg.snap_start_to_free = cfg.snap_start_to_free;
  planner_cfg.snap_goal_to_free = cfg.snap_goal_to_free;
  planner_cfg.snap_search_radius_cells = cfg.snap_search_radius_cells;
  planner_cfg.max_expanded_nodes = cfg.max_expanded_nodes;
  return planner_cfg;
}

PlannerConfig build_simple_detection_config(const FrontierExplorerConfig& cfg) {
  PlannerConfig planner_cfg = build_simple_planner_config(cfg);
  planner_cfg.inflation_radius_m = cfg.detection_inflation_radius_m;
  return planner_cfg;
}

void mark_reachable_cells_simple(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& inflated_occupancy,
    const GridCoord& start_cell,
    std::vector<uint8_t>* reachable) {
  if (!reachable || !map.valid() || !map.in_bounds(start_cell.x, start_cell.y)) {
    return;
  }

  reachable->assign(static_cast<size_t>(map.width * map.height), 0);
  if (is_cell_blocked(map, cfg, start_cell.x, start_cell.y, &inflated_occupancy)) {
    return;
  }

  constexpr int32_t kDx[8] = {1, 1, 0, -1, -1, -1, 0, 1};
  constexpr int32_t kDy[8] = {0, 1, 1, 1, 0, -1, -1, -1};
  std::queue<GridCoord> q;
  q.push(start_cell);
  (*reachable)[static_cast<size_t>(map.index(start_cell.x, start_cell.y))] = 1;

  while (!q.empty()) {
    const GridCoord current = q.front();
    q.pop();

    for (int32_t i = 0; i < 8; ++i) {
      const int32_t nx = current.x + kDx[i];
      const int32_t ny = current.y + kDy[i];
      if (!map.in_bounds(nx, ny) ||
          is_cell_blocked(map, cfg, nx, ny, &inflated_occupancy)) {
        continue;
      }
      const int32_t idx = map.index(nx, ny);
      if ((*reachable)[static_cast<size_t>(idx)] != 0) {
        continue;
      }
      (*reachable)[static_cast<size_t>(idx)] = 1;
      q.push(GridCoord{nx, ny});
    }
  }
}

void detect_frontiers_simple(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& inflated_occupancy,
    const std::vector<uint8_t>& reachable,
    std::vector<GridCoord>* frontier_cells) {
  if (!frontier_cells) {
    return;
  }
  frontier_cells->clear();
  if (!map.valid()) {
    return;
  }

  constexpr int32_t kDx[8] = {1, 1, 0, -1, -1, -1, 0, 1};
  constexpr int32_t kDy[8] = {0, 1, 1, 1, 0, -1, -1, -1};

  for (int32_t y = 0; y < map.height; ++y) {
    for (int32_t x = 0; x < map.width; ++x) {
      const int32_t idx = map.index(x, y);
      if (reachable[static_cast<size_t>(idx)] == 0 ||
          is_cell_blocked(map, cfg, x, y, &inflated_occupancy) ||
          map.data[static_cast<size_t>(idx)] < 0) {
        continue;
      }

      bool is_frontier = false;
      for (int32_t i = 0; i < 8; ++i) {
        const int32_t nx = x + kDx[i];
        const int32_t ny = y + kDy[i];
        if (!map.in_bounds(nx, ny)) {
          continue;
        }
        if (map.data[static_cast<size_t>(map.index(nx, ny))] < 0) {
          is_frontier = true;
          break;
        }
      }

      if (is_frontier) {
        frontier_cells->push_back(GridCoord{x, y});
      }
    }
  }
}

void cluster_frontiers_simple(
    const GridMap2D& map,
    const std::vector<GridCoord>& frontier_cells,
    std::vector<std::vector<GridCoord>>* clusters) {
  if (!clusters) {
    return;
  }
  clusters->clear();
  if (!map.valid() || frontier_cells.empty()) {
    return;
  }

  constexpr int32_t kDx[8] = {1, 1, 0, -1, -1, -1, 0, 1};
  constexpr int32_t kDy[8] = {0, 1, 1, 1, 0, -1, -1, -1};
  std::vector<uint8_t> is_frontier(static_cast<size_t>(map.width * map.height), 0);
  std::vector<uint8_t> clustered(static_cast<size_t>(map.width * map.height), 0);
  for (const GridCoord& cell : frontier_cells) {
    is_frontier[static_cast<size_t>(map.index(cell.x, cell.y))] = 1;
  }

  for (const GridCoord& seed : frontier_cells) {
    const int32_t seed_idx = map.index(seed.x, seed.y);
    if (clustered[static_cast<size_t>(seed_idx)] != 0) {
      continue;
    }

    std::vector<GridCoord> cluster;
    std::queue<GridCoord> q;
    q.push(seed);
    clustered[static_cast<size_t>(seed_idx)] = 1;

    while (!q.empty()) {
      const GridCoord current = q.front();
      q.pop();
      cluster.push_back(current);

      for (int32_t i = 0; i < 8; ++i) {
        const int32_t nx = current.x + kDx[i];
        const int32_t ny = current.y + kDy[i];
        if (!map.in_bounds(nx, ny)) {
          continue;
        }
        const int32_t idx = map.index(nx, ny);
        if (is_frontier[static_cast<size_t>(idx)] == 0 ||
            clustered[static_cast<size_t>(idx)] != 0) {
          continue;
        }
        clustered[static_cast<size_t>(idx)] = 1;
        q.push(GridCoord{nx, ny});
      }
    }

    if (!cluster.empty()) {
      clusters->push_back(std::move(cluster));
    }
  }
}

GridCoord select_cluster_centroid_cell(const std::vector<GridCoord>& cluster) {
  if (cluster.empty()) {
    return {};
  }

  double sum_x = 0.0;
  double sum_y = 0.0;
  for (const GridCoord& cell : cluster) {
    sum_x += static_cast<double>(cell.x);
    sum_y += static_cast<double>(cell.y);
  }
  const double centroid_x = sum_x / static_cast<double>(cluster.size());
  const double centroid_y = sum_y / static_cast<double>(cluster.size());

  GridCoord best = cluster.front();
  double best_dist2 = std::numeric_limits<double>::infinity();
  for (const GridCoord& cell : cluster) {
    const double dx = static_cast<double>(cell.x) - centroid_x;
    const double dy = static_cast<double>(cell.y) - centroid_y;
    const double dist2 = dx * dx + dy * dy;
    if (dist2 < best_dist2) {
      best_dist2 = dist2;
      best = cell;
    }
  }
  return best;
}

bool select_cluster_approach_goal_cell(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy,
    const std::vector<GridCoord>& cluster,
    int32_t snap_search_radius_cells,
    GridCoord* out_seed,
    GridCoord* out_goal) {
  if (!out_seed || !out_goal || cluster.empty()) {
    return false;
  }

  double sum_x = 0.0;
  double sum_y = 0.0;
  for (const GridCoord& cell : cluster) {
    sum_x += static_cast<double>(cell.x);
    sum_y += static_cast<double>(cell.y);
  }
  const double centroid_x = sum_x / static_cast<double>(cluster.size());
  const double centroid_y = sum_y / static_cast<double>(cluster.size());

  bool found = false;
  double best_score = std::numeric_limits<double>::infinity();
  GridCoord best_seed{};
  GridCoord best_goal{};
  const int32_t effective_snap_radius =
      std::max<int32_t>(snap_search_radius_cells, 16);

  for (const GridCoord& seed : cluster) {
    GridCoord candidate_goal = seed;
    if (is_cell_blocked(map, cfg, seed.x, seed.y, &occupancy)) {
      if (!find_nearest_free_cell(
              map,
              cfg,
              occupancy,
              seed,
              effective_snap_radius,
              &candidate_goal)) {
        continue;
      }
    }

    const double seed_dx = static_cast<double>(seed.x) - centroid_x;
    const double seed_dy = static_cast<double>(seed.y) - centroid_y;
    const double goal_dx = static_cast<double>(candidate_goal.x) - centroid_x;
    const double goal_dy = static_cast<double>(candidate_goal.y) - centroid_y;
    const double snap_dx =
        static_cast<double>(candidate_goal.x - seed.x);
    const double snap_dy =
        static_cast<double>(candidate_goal.y - seed.y);
    const double score =
        goal_dx * goal_dx + goal_dy * goal_dy +
        0.25 * (seed_dx * seed_dx + seed_dy * seed_dy) +
        0.5 * (snap_dx * snap_dx + snap_dy * snap_dy);
    if (score < best_score) {
      best_score = score;
      best_seed = seed;
      best_goal = candidate_goal;
      found = true;
    }
  }

  if (!found) {
    return false;
  }
  *out_seed = best_seed;
  *out_goal = best_goal;
  return true;
}

std::vector<double> compute_clearance_field(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy) {
  const int32_t total_cells = map.width * map.height;
  const double kInf = std::numeric_limits<double>::infinity();
  std::vector<double> clearance_m(static_cast<size_t>(total_cells), kInf);

  struct QueueNode {
    int32_t idx = -1;
    double distance_m = 0.0;
  };
  struct MinDistance {
    bool operator()(const QueueNode& a, const QueueNode& b) const {
      return a.distance_m > b.distance_m;
    }
  };

  std::priority_queue<QueueNode, std::vector<QueueNode>, MinDistance> q;
  for (int32_t y = 0; y < map.height; ++y) {
    for (int32_t x = 0; x < map.width; ++x) {
      if (!is_cell_blocked(map, cfg, x, y, &occupancy)) {
        continue;
      }
      const int32_t idx = map.index(x, y);
      clearance_m[static_cast<size_t>(idx)] = 0.0;
      q.push(QueueNode{idx, 0.0});
    }
  }

  constexpr int32_t kDx[8] = {1, -1, 0, 0, 1, -1, 1, -1};
  constexpr int32_t kDy[8] = {0, 0, 1, -1, 1, -1, -1, 1};

  while (!q.empty()) {
    const QueueNode node = q.top();
    q.pop();
    if (node.distance_m >
        clearance_m[static_cast<size_t>(node.idx)] + 1e-9) {
      continue;
    }

    const int32_t cx = node.idx % map.width;
    const int32_t cy = node.idx / map.width;
    for (int32_t i = 0; i < 8; ++i) {
      const int32_t nx = cx + kDx[i];
      const int32_t ny = cy + kDy[i];
      if (!map.in_bounds(nx, ny)) {
        continue;
      }
      const bool diagonal = (kDx[i] != 0 && kDy[i] != 0);
      const double step_m =
          map.resolution_m * (diagonal ? 1.4142135623730951 : 1.0);
      const double candidate_distance = node.distance_m + step_m;
      const int32_t nidx = map.index(nx, ny);
      if (candidate_distance + 1e-9 >=
          clearance_m[static_cast<size_t>(nidx)]) {
        continue;
      }
      clearance_m[static_cast<size_t>(nidx)] = candidate_distance;
      q.push(QueueNode{nidx, candidate_distance});
    }
  }

  return clearance_m;
}

double clearance_penalty_for_cell(double clearance_m) {
  constexpr double kDesiredExtraClearanceM = 0.10;
  constexpr double kPenaltyWeight = 2.0;
  if (!std::isfinite(clearance_m) || clearance_m >= kDesiredExtraClearanceM) {
    return 0.0;
  }
  const double shortfall_ratio =
      (kDesiredExtraClearanceM - clearance_m) / kDesiredExtraClearanceM;
  return kPenaltyWeight * shortfall_ratio;
}

double path_length_m(const GridMap2D& map, const std::vector<GridCoord>& path_grid) {
  if (path_grid.size() < 2) {
    return 0.0;
  }
  double length_m = 0.0;
  for (size_t i = 1; i < path_grid.size(); ++i) {
    const int32_t dx = path_grid[i].x - path_grid[i - 1].x;
    const int32_t dy = path_grid[i].y - path_grid[i - 1].y;
    const bool diagonal = (dx != 0 && dy != 0);
    length_m += map.resolution_m * (diagonal ? 1.4142135623730951 : 1.0);
  }
  return length_m;
}

PlanResult plan_to_grid_with_clearance_cost(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy,
    const GridCoord& start_in,
    const GridCoord& goal_in) {
  PlanResult result;
  if (!map.valid()) {
    result.message = "invalid occupancy grid";
    return result;
  }
  if (!map.in_bounds(start_in.x, start_in.y) ||
      !map.in_bounds(goal_in.x, goal_in.y)) {
    result.message = "start or goal outside map bounds";
    return result;
  }

  GridCoord start = start_in;
  GridCoord goal = goal_in;
  if (is_cell_blocked(map, cfg, start.x, start.y, &occupancy)) {
    if (!cfg.snap_start_to_free ||
        !find_nearest_free_cell(
            map,
            cfg,
            occupancy,
            start,
            cfg.snap_search_radius_cells,
            &start)) {
      result.message = "start cell is occupied";
      return result;
    }
  }
  if (is_cell_blocked(map, cfg, goal.x, goal.y, &occupancy)) {
    if (!cfg.snap_goal_to_free ||
        !find_nearest_free_cell(
            map,
            cfg,
            occupancy,
            goal,
            cfg.snap_search_radius_cells,
            &goal)) {
      result.message = "goal cell is occupied";
      return result;
    }
  }

  const std::vector<double> clearance_m =
      compute_clearance_field(map, cfg, occupancy);

  struct OpenNode {
    int32_t idx = -1;
    double f = 0.0;
    double g = 0.0;
  };
  struct MinHeapByF {
    bool operator()(const OpenNode& a, const OpenNode& b) const {
      if (a.f == b.f) {
        return a.g > b.g;
      }
      return a.f > b.f;
    }
  };

  constexpr int32_t kCardinalDx[4] = {1, -1, 0, 0};
  constexpr int32_t kCardinalDy[4] = {0, 0, 1, -1};
  constexpr int32_t kAllDx[8] = {1, -1, 0, 0, 1, -1, 1, -1};
  constexpr int32_t kAllDy[8] = {0, 0, 1, -1, 1, -1, -1, 1};
  const int32_t neighbor_count = cfg.allow_diagonal ? 8 : 4;
  const int32_t total_cells = map.width * map.height;
  const int32_t start_idx = map.index(start.x, start.y);
  const int32_t goal_idx = map.index(goal.x, goal.y);
  const double kInf = std::numeric_limits<double>::infinity();

  std::vector<double> g_cost(static_cast<size_t>(total_cells), kInf);
  std::vector<int32_t> came_from(static_cast<size_t>(total_cells), -1);
  std::vector<uint8_t> closed(static_cast<size_t>(total_cells), 0);
  std::priority_queue<OpenNode, std::vector<OpenNode>, MinHeapByF> open_set;

  auto heuristic = [&](int32_t x, int32_t y) -> double {
    const double dx_m =
        static_cast<double>(x - goal.x) * map.resolution_m;
    const double dy_m =
        static_cast<double>(y - goal.y) * map.resolution_m;
    return std::sqrt(dx_m * dx_m + dy_m * dy_m);
  };

  g_cost[static_cast<size_t>(start_idx)] = 0.0;
  open_set.push(OpenNode{start_idx, heuristic(start.x, start.y), 0.0});

  int32_t expanded_nodes = 0;
  bool found = false;
  while (!open_set.empty()) {
    const OpenNode node = open_set.top();
    open_set.pop();
    if (closed[static_cast<size_t>(node.idx)] != 0) {
      continue;
    }
    closed[static_cast<size_t>(node.idx)] = 1;
    ++expanded_nodes;

    if (expanded_nodes > cfg.max_expanded_nodes) {
      result.message = "planning aborted: expansion limit reached";
      return result;
    }
    if (node.idx == goal_idx) {
      found = true;
      break;
    }

    const int32_t cx = node.idx % map.width;
    const int32_t cy = node.idx / map.width;
    for (int32_t i = 0; i < neighbor_count; ++i) {
      const int32_t dx = cfg.allow_diagonal ? kAllDx[i] : kCardinalDx[i];
      const int32_t dy = cfg.allow_diagonal ? kAllDy[i] : kCardinalDy[i];
      const int32_t nx = cx + dx;
      const int32_t ny = cy + dy;
      if (!map.in_bounds(nx, ny) ||
          is_cell_blocked(map, cfg, nx, ny, &occupancy)) {
        continue;
      }

      const bool diagonal = (dx != 0 && dy != 0);
      if (diagonal && cfg.prevent_corner_cutting) {
        if (is_cell_blocked(map, cfg, cx + dx, cy, &occupancy) ||
            is_cell_blocked(map, cfg, cx, cy + dy, &occupancy)) {
          continue;
        }
      }

      const int32_t nidx = map.index(nx, ny);
      if (closed[static_cast<size_t>(nidx)] != 0) {
        continue;
      }

      const double step_cost_m =
          map.resolution_m * (diagonal ? 1.4142135623730951 : 1.0);
      const double node_clearance_penalty =
          clearance_penalty_for_cell(clearance_m[static_cast<size_t>(node.idx)]);
      const double next_clearance_penalty =
          clearance_penalty_for_cell(clearance_m[static_cast<size_t>(nidx)]);
      const double clearance_multiplier =
          1.0 + 0.5 * (node_clearance_penalty + next_clearance_penalty);
      const double tentative_g =
          g_cost[static_cast<size_t>(node.idx)] +
          step_cost_m * clearance_multiplier;
      if (tentative_g >= g_cost[static_cast<size_t>(nidx)]) {
        continue;
      }

      came_from[static_cast<size_t>(nidx)] = node.idx;
      g_cost[static_cast<size_t>(nidx)] = tentative_g;
      open_set.push(OpenNode{nidx, tentative_g + heuristic(nx, ny), tentative_g});
    }
  }

  if (!found) {
    result.message = "no path found";
    return result;
  }

  std::vector<GridCoord> path_grid_reversed;
  for (int32_t idx = goal_idx; idx >= 0; idx = came_from[static_cast<size_t>(idx)]) {
    path_grid_reversed.push_back(GridCoord{idx % map.width, idx / map.width});
    if (idx == start_idx) {
      break;
    }
  }
  if (path_grid_reversed.empty() || !(path_grid_reversed.back() == start)) {
    result.message = "failed to reconstruct path";
    return result;
  }

  result.path_grid.assign(path_grid_reversed.rbegin(), path_grid_reversed.rend());
  // Keep the clearance-optimized polyline rather than re-simplifying with a
  // collision-only shortcut pass.
  result.path_world.reserve(result.path_grid.size());
  for (const GridCoord& c : result.path_grid) {
    double wx = 0.0;
    double wy = 0.0;
    grid_to_world(map, c, &wx, &wy);
    result.path_world.push_back(core::Vector3d{wx, wy, 0.0});
  }
  result.success = true;
  result.message = "ok";
  return result;
}

}  // namespace

FrontierPlanResult plan_to_largest_frontier(
    const GridMap2D& map,
    const core::Vector3d& start_world,
    const FrontierExplorerConfig& cfg) {
  FrontierPlanResult result;
  if (!map.valid()) {
    result.message = "invalid occupancy grid";
    return result;
  }

  const PlannerConfig detection_cfg = build_simple_detection_config(cfg);
  const PlannerConfig planner_cfg = build_simple_planner_config(cfg);
  const std::vector<int8_t> inflated_detection = inflate_obstacles(map, detection_cfg);
  const std::vector<int8_t> inflated_occupancy = inflate_obstacles(map, planner_cfg);

  GridCoord start_cell{};
  if (!world_to_grid(map, start_world.x, start_world.y, &start_cell)) {
    result.message = "robot pose outside map bounds";
    return result;
  }
  if (is_cell_blocked(map, detection_cfg, start_cell.x, start_cell.y, &inflated_detection)) {
    if (!detection_cfg.snap_start_to_free ||
        !find_nearest_free_cell(
            map,
            detection_cfg,
            inflated_detection,
            start_cell,
            detection_cfg.snap_search_radius_cells,
            &start_cell)) {
      result.message = "robot start cell is blocked";
      return result;
    }
  }

  std::vector<uint8_t> reachable;
  mark_reachable_cells_simple(
      map,
      detection_cfg,
      inflated_detection,
      start_cell,
      &reachable);

  std::vector<GridCoord> frontier_cells;
  detect_frontiers_simple(
      map,
      detection_cfg,
      inflated_detection,
      reachable,
      &frontier_cells);
  result.frontier_cell_count = static_cast<int32_t>(frontier_cells.size());
  result.frontier_cells = frontier_cells;
  if (frontier_cells.empty()) {
    result.message = "no reachable frontier cells";
    return result;
  }

  std::vector<std::vector<GridCoord>> clusters;
  cluster_frontiers_simple(map, frontier_cells, &clusters);
  result.cluster_count = static_cast<int32_t>(clusters.size());
  if (clusters.empty()) {
    result.message = "no frontier clusters";
    return result;
  }

  int32_t best_cluster_index = -1;
  int32_t best_cluster_size = -1;
  for (size_t i = 0; i < clusters.size(); ++i) {
    const int32_t cluster_size = static_cast<int32_t>(clusters[i].size());
    if (cluster_size > best_cluster_size) {
      best_cluster_size = cluster_size;
      best_cluster_index = static_cast<int32_t>(i);
    }
  }

  const std::vector<GridCoord>& best_cluster =
      clusters[static_cast<size_t>(best_cluster_index)];
  GridCoord goal_seed = select_cluster_centroid_cell(best_cluster);
  GridCoord goal_cell = goal_seed;
  if (!select_cluster_approach_goal_cell(
          map,
          planner_cfg,
          inflated_occupancy,
          best_cluster,
          planner_cfg.snap_search_radius_cells,
          &goal_seed,
          &goal_cell)) {
    result.message = "largest frontier cluster has no nearby free approach cell";
    return result;
  }

  const PlanResult planned = plan_to_grid_with_clearance_cost(
      map,
      planner_cfg,
      inflated_occupancy,
      start_cell,
      goal_cell);
  if (!planned.success || planned.path_grid.empty() || planned.path_world.empty()) {
    result.message = "largest frontier cluster unreachable";
    return result;
  }

  result.success = true;
  result.message = "ok";
  result.goal_cell = planned.path_grid.back();
  result.selected_seed = goal_seed;
  result.path_grid = planned.path_grid;
  result.path_world = planned.path_world;
  result.selected_cluster_cells = best_cluster;
  result.selected_cluster_size = best_cluster_size;
  result.selected_path_length_m = path_length_m(map, planned.path_grid);

  std::ostringstream log;
  log << "[planning][simplified] success=1"
      << " frontier_cells=" << result.frontier_cell_count
      << " clusters=" << result.cluster_count
      << " selected_cluster_size=" << result.selected_cluster_size
      << " path_length_m=" << result.selected_path_length_m
      << " selected_seed=(" << result.selected_seed.x << "," << result.selected_seed.y << ")";
  wasm_log_line(log.str());

  return result;
}

}  // namespace planning::simplified
