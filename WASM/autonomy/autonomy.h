#pragma once
#include <atomic>

namespace autonomy{

    enum class AutonomySubstate : uint8_t {
        IDLE = 0,
        PLANNER_INIT = 1,
        WAITING_FOR_PATH = 2,
        FRONTIER_DETECTION = 3,
        GOAL_SELECTION = 4,
        PLANNING_GOAL = 5,
        FOLLOWING_PATH = 6,
        NO_PATH_AVAILABLE = 7,
        SCAN_REQUESTED = 8,
        SCANNING = 9,
    };


    static const char* autonomy_substate_name(AutonomySubstate state) {
        switch (state) {
            case AutonomySubstate::IDLE: return "IDLE";
            case AutonomySubstate::PLANNER_INIT: return "PLANNER_INIT";
            case AutonomySubstate::WAITING_FOR_PATH: return "WAITING_FOR_PATH";
            case AutonomySubstate::FRONTIER_DETECTION: return "FRONTIER_DETECTION";
            case AutonomySubstate::GOAL_SELECTION: return "GOAL_SELECTION";
            case AutonomySubstate::PLANNING_GOAL: return "PLANNING_GOAL";
            case AutonomySubstate::FOLLOWING_PATH: return "FOLLOWING_PATH";
            case AutonomySubstate::NO_PATH_AVAILABLE: return "NO_PATH_AVAILABLE";
            case AutonomySubstate::SCAN_REQUESTED: return "SCAN_REQUESTED";
            case AutonomySubstate::SCANNING: return "SCANNING";
        }
        return "UNKNOWN";
    }

}; // namespace autonomy
