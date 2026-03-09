#include "visualization.h"
#include "map.h"

#include <stdint.h>

namespace mapping {
namespace visualization {

void render_map_frame(
    Map& map,
    int32_t   pose_count,
    int32_t   point_count,
    int32_t   width,
    int32_t   height,
    double    timestamp,
    MapFrameMetadata& out_frame)
{
    map.draw_map(pose_count, point_count, width, height);

    out_frame.timestamp = timestamp;
    out_frame.width     = map.get_image_width();
    out_frame.height    = map.get_image_height();
    out_frame.channels  = 4;
    out_frame.data_ptr  = static_cast<uint32_t>(
        reinterpret_cast<uintptr_t>(map.get_image_rgba_ptr()));
    out_frame.data_size = map.get_image_rgba_size();

    rerun_log_map_frame(&out_frame);
}

} // namespace visualization
} // namespace mapping
