#pragma once

#include <cstdint>
#include <vector>

#include "mapping/map_snapshot.h"
#include "core/pose/se3.h"
#include "planning/planner.h"

namespace planning::bridge {

struct PlanningOverlay {
  uint64_t source_map_revision = 0;
  bool goal_enabled = false;
  GridCoord goal_cell{};
  std::vector<GridCoord> path_grid;
  std::vector<GridCoord> frontier_candidates;
  std::vector<GridCoord> selected_frontier_cluster;
  bool selected_frontier_seed_enabled = false;
  GridCoord selected_frontier_seed{};
};

enum class PlannerTelemetryMode : int32_t {
  None = 0,
  DirectGoalDStar = 1,
  Frontier = 2,
};

struct PlannerTelemetryFrame {
  uint64_t sequence = 0;
  uint64_t source_map_revision = 0;
  uint64_t goal_revision = 0;
  double timestamp = 0.0;
  int32_t planner_mode = static_cast<int32_t>(PlannerTelemetryMode::None);
  int32_t success = 0;
  int32_t goal_enabled = 0;
  int32_t start_cell_valid = 0;
  int32_t start_x = 0;
  int32_t start_y = 0;
  int32_t goal_x = 0;
  int32_t goal_y = 0;
  int32_t selected_frontier_seed_enabled = 0;
  int32_t selected_frontier_seed_x = 0;
  int32_t selected_frontier_seed_y = 0;
  uint32_t path_grid_ptr = 0;
  int32_t path_grid_count = 0;
  uint32_t frontier_candidates_ptr = 0;
  int32_t frontier_candidates_count = 0;
  uint32_t selected_frontier_cluster_ptr = 0;
  int32_t selected_frontier_cluster_count = 0;
  uint32_t changed_cells_ptr = 0;
  int32_t changed_cells_count = 0;
  uint32_t expanded_cells_ptr = 0;
  int32_t expanded_cells_count = 0;
  uint32_t message_length = 0;
  char message[128]{};
} __attribute__((packed));

using GoalChangeCallback = void (*)();

void set_goal_map_pixel(int32_t x, int32_t y);
void clear_goal();
uint64_t latest_goal_revision();
bool has_active_goal();
void set_goal_change_callback(GoalChangeCallback callback);
bool is_overlay_path_valid(
    const mapping::MapSnapshot& snapshot,
    const PlanningOverlay& overlay);
bool does_new_occupancy_intersect_overlay_path(
    const mapping::MapSnapshot& snapshot,
    const PlanningOverlay& overlay,
    const std::vector<GridCoord>& newly_occupied_cells);
void invalidate_current_plan();

PlanningOverlay update_plan_overlay(
    const mapping::MapSnapshot& snapshot,
    int32_t render_width,
    int32_t render_height);

// Copies the latest planned world path and returns its revision id.
// Revision only changes when path content changes.
uint64_t copy_latest_plan_world(std::vector<core::Vector3d>* out_path);
uint64_t latest_overlay_revision();

}  // namespace planning::bridge
