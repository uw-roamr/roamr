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
};

using GoalChangeCallback = void (*)();

void set_goal_map_pixel(int32_t x, int32_t y);
void clear_goal();
uint64_t latest_goal_revision();
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

}  // namespace planning::bridge
