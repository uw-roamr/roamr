#pragma once
#include <cstdint>

#include "mapping/map_metadata.h"
#include "mapping/map_snapshot.h"
#include "planning/planner_bridge.h"

namespace mapping {
namespace visualization {

// Render the occupancy grid into out_frame and ship it to the host via
// rerun_log_map_frame.
void render_map_frame(
    const MapSnapshot& snapshot,
    const PoseTrailState& pose_trail,
    const planning::bridge::PlanningOverlay& overlay,
    int32_t width,
    int32_t height,
    MapImage& out_frame);

} // namespace visualization
} // namespace mapping
