#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "planning/planner.h"

namespace planning {

struct FrontierExplorerConfig {
  int8_t occupied_threshold = 50;
  bool allow_diagonal = true;
  bool prevent_corner_cutting = true;
  double inflation_radius_m = 0.20;
  bool simplify_path = true;
  bool snap_start_to_free = true;
  bool snap_goal_to_free = true;
  int32_t snap_search_radius_cells = 10;
  int32_t max_expanded_nodes = 250000;
  int32_t min_cluster_size = 4;
};

struct FrontierPlanResult {
  bool success = false;
  std::string message;
  GridCoord goal_cell{};
  std::vector<GridCoord> path_grid;
  std::vector<core::Vector3d> path_world;
  int32_t frontier_cell_count = 0;
  int32_t cluster_count = 0;
  int32_t selected_cluster_size = 0;
};

FrontierPlanResult plan_to_nearest_frontier(
    const GridMap2D& map,
    const core::Vector3d& start_world,
    const FrontierExplorerConfig& cfg = {});

}  // namespace planning
