#pragma once

#include <cstdint>
#include <vector>

#include "core/pose/se3.h"

namespace mapping {
class Map;
}

namespace planning::bridge {

void set_goal_map_pixel(int32_t x, int32_t y);
void clear_goal();

// Updates planner state and pushes the planned path overlay into map.cpp state.
void update_plan_overlay(
    mapping::Map& map,
    const core::PoseSE3d& body_to_world,
    int32_t render_width,
    int32_t render_height);

// Copies the latest planned world path and returns its revision id.
// Revision only changes when path content changes.
uint64_t copy_latest_plan_world(std::vector<core::Vector3d>* out_path);

}  // namespace planning::bridge
