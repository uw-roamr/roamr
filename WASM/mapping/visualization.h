#pragma once
#include <cstdint>
#include "mapping/map_update.h"

namespace mapping {
class Map;

namespace visualization {

// Render the occupancy grid into out_frame and ship it to the host via
// rerun_log_map_frame. Called directly from the map-update thread.
void render_map_frame(
    const Map& map,
    int32_t pose_count,
    int32_t width,
    int32_t height,
    double  timestamp,
    MapImage& out_frame);

} // namespace visualization
} // namespace mapping
