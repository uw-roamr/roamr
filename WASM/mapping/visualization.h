#pragma once
#include <cstdint>

#include "mapping/map_metadata.h"
#include "mapping/map_snapshot.h"
#include "planning/planner_bridge.h"

namespace mapping {
namespace visualization {

// Render the visualization layers and ship each one to the host via
// rerun_log_map_frame. The host distinguishes frames by MapImage.layer_id.
void render_map_frame(
    const MapSnapshot& snapshot,
    const PoseTrailState& pose_trail,
    const planning::bridge::PlanningOverlay& overlay,
    uint64_t overlay_revision,
    int32_t width,
    int32_t height,
    MapImage& out_frame);

} // namespace visualization
} // namespace mapping
