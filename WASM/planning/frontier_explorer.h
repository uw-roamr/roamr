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
  double detection_inflation_radius_m = 0.02;
  double inflation_radius_m = 0.15;
  bool simplify_path = true;
  bool snap_start_to_free = true;
  bool snap_goal_to_free = true;
  int32_t snap_search_radius_cells = 10;
  int32_t max_expanded_nodes = 250000;
  int32_t min_cluster_size = 4;
  double goal_standoff_m = 0.18;
  double min_standoff_path_progress_m = 0.10;
};

struct FrontierPlanResult {
  bool success = false;
  std::string message;
  GridCoord goal_cell{};
  GridCoord selected_seed{};
  std::vector<GridCoord> path_grid;
  std::vector<core::Vector3d> path_world;
  std::vector<GridCoord> selected_cluster_cells;
  int32_t frontier_cell_count = 0;
  int32_t cluster_count = 0;
  int32_t selected_cluster_size = 0;
  double selected_path_length_m = 0.0;
  double selected_heading_delta_rad = 0.0;
  double selected_goal_standoff_m = 0.0;
};

FrontierPlanResult plan_to_nearest_frontier(
    const GridMap2D& map,
    const core::Vector3d& start_world,
    const FrontierExplorerConfig& cfg = {});

std::vector<GridCoord> collect_frontier_goal_cells(
    const GridMap2D& map,
    const core::Vector3d& start_world,
    const FrontierExplorerConfig& cfg = {});

std::vector<GridCoord> collect_reachable_frontier_cells(
    const GridMap2D& map,
    const core::Vector3d& start_world,
    const FrontierExplorerConfig& cfg = {});

bool is_frontier_goal_candidate(
    const GridMap2D& map,
    const GridCoord& cell,
    const FrontierExplorerConfig& cfg = {});

}  // namespace planning
