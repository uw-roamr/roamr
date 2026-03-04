#pragma once

#include <cstdint>

#include "core/math_utils.h"

namespace planning::bridge {

void set_goal_map_pixel(int32_t x, int32_t y);
void clear_goal();

// Updates planner state and pushes the planned path overlay into map.cpp state.
void update_plan_overlay(
    const core::Vector3d& robot_translation_world,
    int32_t render_width,
    int32_t render_height);

}  // namespace planning::bridge

