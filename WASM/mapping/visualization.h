#pragma once
#include <cstdint>
#include "map_api.h"

namespace mapping {
namespace visualization {

// Render the occupancy grid into out_frame and ship it to the host via
// rerun_log_map_frame. Called directly from the map-update thread.
void render_map_frame(
    int32_t pose_count,
    int32_t point_count,
    int32_t width,
    int32_t height,
    double  timestamp,
    MapFrame& out_frame);

} // namespace visualization
} // namespace mapping
