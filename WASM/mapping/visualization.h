#pragma once
#include <cstdint>
#include "map_api.h"

namespace mapping {
namespace visualization {

// Parameters needed to (re-)render the occupancy grid image.
struct MapRenderRequest {
    int32_t pose_count  = 0;
    int32_t point_count = 0;
    int32_t width       = 256;
    int32_t height      = 256;
    double  timestamp   = 0.0;
};

// Synchronous render: draw_map → fill out_frame → rerun_log_map_frame.
// Can be called directly when synchronous behavior is needed.
void render_map_frame(
    int32_t pose_count,
    int32_t point_count,
    int32_t width,
    int32_t height,
    double  timestamp,
    MapFrame& out_frame);

// Non-blocking: enqueue a render request. If a previous request has not yet
// been consumed by the telemetry thread, it is overwritten (latest wins).
void request_render(const MapRenderRequest& req);

// Blocking: wait for a pending render request, render into out_frame, then
// return. Designed to be called in a loop from the dedicated telemetry thread.
void wait_and_render(MapFrame& out_frame);

} // namespace visualization
} // namespace mapping
