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

void set_goal_map_pixel(int32_t x, int32_t y);
void clear_goal();

PlanningOverlay update_plan_overlay(
    const mapping::MapSnapshot& snapshot,
    int32_t render_width,
    int32_t render_height);

// Copies the latest planned world path and returns its revision id.
// Revision only changes when path content changes.
uint64_t copy_latest_plan_world(std::vector<core::Vector3d>* out_path);

}  // namespace planning::bridge
