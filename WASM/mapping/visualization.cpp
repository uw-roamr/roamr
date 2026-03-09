#include "visualization.h"
#include "map_api.h"

#include <stdint.h>

namespace mapping {
namespace visualization {

void render_map_frame(
    int32_t   pose_count,
    int32_t   point_count,
    int32_t   width,
    int32_t   height,
    double    timestamp,
    MapFrame& out_frame)
{
    draw_map(pose_count, point_count, width, height);

    out_frame.timestamp = timestamp;
    out_frame.width     = get_image_width();
    out_frame.height    = get_image_height();
    out_frame.channels  = 4;
    out_frame.data_ptr  = static_cast<uint32_t>(
        reinterpret_cast<uintptr_t>(get_image_rgba_ptr()));
    out_frame.data_size = get_image_rgba_size();

    rerun_log_map_frame(&out_frame);
}

} // namespace visualization
} // namespace mapping
