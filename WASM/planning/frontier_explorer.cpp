#include "planning/frontier_explorer.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <queue>
#include <utility>
#include <vector>

namespace planning {
namespace {

PlannerConfig build_planner_config(const FrontierExplorerConfig& cfg) {
  PlannerConfig planner_cfg;
  planner_cfg.occupied_threshold = cfg.occupied_threshold;
  planner_cfg.treat_unknown_as_occupied = true;
  planner_cfg.allow_diagonal = cfg.allow_diagonal;
  planner_cfg.prevent_corner_cutting = cfg.prevent_corner_cutting;
  planner_cfg.inflation_radius_m = cfg.inflation_radius_m;
  planner_cfg.simplify_path = cfg.simplify_path;
  planner_cfg.snap_start_to_free = cfg.snap_start_to_free;
  planner_cfg.snap_goal_to_free = cfg.snap_goal_to_free;
  planner_cfg.snap_search_radius_cells = cfg.snap_search_radius_cells;
  planner_cfg.max_expanded_nodes = cfg.max_expanded_nodes;
  return planner_cfg;
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

void mark_reachable_cells(
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

  constexpr int32_t kCardinalDx[4] = {1, -1, 0, 0};
  constexpr int32_t kCardinalDy[4] = {0, 0, 1, -1};
  constexpr int32_t kAllDx[8] = {1, -1, 0, 0, 1, -1, 1, -1};
  constexpr int32_t kAllDy[8] = {0, 0, 1, -1, 1, -1, -1, 1};
  const int32_t neighbor_count = cfg.allow_diagonal ? 8 : 4;

  std::queue<GridCoord> q;
  q.push(start_cell);
  (*reachable)[static_cast<size_t>(map.index(start_cell.x, start_cell.y))] = 1;

  while (!q.empty()) {
    const GridCoord current = q.front();
    q.pop();

    for (int32_t i = 0; i < neighbor_count; ++i) {
      const int32_t dx = cfg.allow_diagonal ? kAllDx[i] : kCardinalDx[i];
      const int32_t dy = cfg.allow_diagonal ? kAllDy[i] : kCardinalDy[i];
      const int32_t nx = current.x + dx;
      const int32_t ny = current.y + dy;
      if (!map.in_bounds(nx, ny) ||
          is_cell_blocked(map, cfg, nx, ny, &inflated_occupancy)) {
        continue;
      }

      const bool diagonal = (dx != 0 && dy != 0);
      if (diagonal && cfg.prevent_corner_cutting) {
        if (is_cell_blocked(map, cfg, current.x + dx, current.y, &inflated_occupancy) ||
            is_cell_blocked(map, cfg, current.x, current.y + dy, &inflated_occupancy)) {
          continue;
        }
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

void detect_frontiers(
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

  constexpr int32_t kNeighborDx[8] = {1, 1, 0, -1, -1, -1, 0, 1};
  constexpr int32_t kNeighborDy[8] = {0, 1, 1, 1, 0, -1, -1, -1};

  for (int32_t y = 0; y < map.height; ++y) {
    for (int32_t x = 0; x < map.width; ++x) {
      const int32_t idx = map.index(x, y);
      if (reachable[static_cast<size_t>(idx)] == 0) {
        continue;
      }
      if (is_cell_blocked(map, cfg, x, y, &inflated_occupancy)) {
        continue;
      }
      const int8_t value = map.data[static_cast<size_t>(idx)];
      if (value < 0 || value >= cfg.occupied_threshold) {
        continue;
      }

      bool has_unknown_neighbor = false;
      for (int32_t i = 0; i < 8; ++i) {
        const int32_t nx = x + kNeighborDx[i];
        const int32_t ny = y + kNeighborDy[i];
        if (!map.in_bounds(nx, ny)) {
          continue;
        }
        const int8_t neighbor_value = map.data[static_cast<size_t>(map.index(nx, ny))];
        if (neighbor_value < 0) {
          has_unknown_neighbor = true;
          break;
        }
      }
      if (has_unknown_neighbor) {
        frontier_cells->push_back(GridCoord{x, y});
      }
    }
  }
}

void cluster_frontiers(
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

  constexpr int32_t kNeighborDx[8] = {1, 1, 0, -1, -1, -1, 0, 1};
  constexpr int32_t kNeighborDy[8] = {0, 1, 1, 1, 0, -1, -1, -1};

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
        const int32_t nx = current.x + kNeighborDx[i];
        const int32_t ny = current.y + kNeighborDy[i];
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

GridCoord select_cluster_goal_cell(const std::vector<GridCoord>& cluster) {
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

  GridCoord best_cell = cluster.front();
  double best_dist2 = std::numeric_limits<double>::infinity();
  for (const GridCoord& cell : cluster) {
    const double dx = static_cast<double>(cell.x) - centroid_x;
    const double dy = static_cast<double>(cell.y) - centroid_y;
    const double dist2 = dx * dx + dy * dy;
    if (dist2 < best_dist2) {
      best_dist2 = dist2;
      best_cell = cell;
    }
  }
  return best_cell;
}

}  // namespace

FrontierPlanResult plan_to_nearest_frontier(
    const GridMap2D& map,
    const core::Vector3d& start_world,
    const FrontierExplorerConfig& cfg) {
  FrontierPlanResult result;
  if (!map.valid()) {
    result.message = "invalid occupancy grid";
    return result;
  }

  const PlannerConfig planner_cfg = build_planner_config(cfg);
  const std::vector<int8_t> inflated_occupancy = inflate_obstacles(map, planner_cfg);

  GridCoord start_cell{};
  if (!world_to_grid(map, start_world.x, start_world.y, &start_cell)) {
    result.message = "robot pose outside map bounds";
    return result;
  }
  if (is_cell_blocked(map, planner_cfg, start_cell.x, start_cell.y, &inflated_occupancy)) {
    if (!planner_cfg.snap_start_to_free ||
        !find_nearest_free_cell(
            map,
            planner_cfg,
            inflated_occupancy,
            start_cell,
            planner_cfg.snap_search_radius_cells,
            &start_cell)) {
      result.message = "robot start cell is blocked";
      return result;
    }
  }

  std::vector<uint8_t> reachable;
  mark_reachable_cells(map, planner_cfg, inflated_occupancy, start_cell, &reachable);

  std::vector<GridCoord> frontier_cells;
  detect_frontiers(map, planner_cfg, inflated_occupancy, reachable, &frontier_cells);
  result.frontier_cell_count = static_cast<int32_t>(frontier_cells.size());
  if (frontier_cells.empty()) {
    result.message = "no reachable frontier cells";
    return result;
  }

  std::vector<std::vector<GridCoord>> clusters;
  cluster_frontiers(map, frontier_cells, &clusters);
  result.cluster_count = static_cast<int32_t>(clusters.size());
  if (clusters.empty()) {
    result.message = "no frontier clusters";
    return result;
  }

  AStarPlanner planner(planner_cfg);
  double best_path_length = std::numeric_limits<double>::infinity();
  int32_t best_cluster_size = -1;

  for (const std::vector<GridCoord>& cluster : clusters) {
    if (static_cast<int32_t>(cluster.size()) < cfg.min_cluster_size) {
      continue;
    }

    const GridCoord goal_seed = select_cluster_goal_cell(cluster);
    const PlanResult planned = planner.plan_to_grid(map, start_cell, goal_seed);
    if (!planned.success || planned.path_grid.empty() || planned.path_world.empty()) {
      continue;
    }

    const double candidate_length = path_length_m(planned.path_world);
    const int32_t cluster_size = static_cast<int32_t>(cluster.size());
    const bool shorter_path = candidate_length + 1e-6 < best_path_length;
    const bool same_length_larger_cluster =
        std::abs(candidate_length - best_path_length) <= 1e-6 &&
        cluster_size > best_cluster_size;
    if (!shorter_path && !same_length_larger_cluster) {
      continue;
    }

    best_path_length = candidate_length;
    best_cluster_size = cluster_size;
    result.success = true;
    result.message = "ok";
    result.goal_cell = planned.path_grid.back();
    result.path_grid = planned.path_grid;
    result.path_world = planned.path_world;
    result.selected_cluster_size = cluster_size;
  }

  if (!result.success) {
    result.message = "no reachable frontier cluster";
  }
  return result;
}

}  // namespace planning
