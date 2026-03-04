#pragma once

#include <cstdint>

#include "core/coordinate_frames.h"

namespace planning::bridge {

void set_goal_map_pixel(int32_t x, int32_t y);
void clear_goal();

// Updates planner state and pushes the planned path overlay into map.cpp state.
void update_plan_overlay(
    const core::PoseSE3d& body_to_world,
    int32_t render_width,
    int32_t render_height);

}  // namespace planning::bridge
