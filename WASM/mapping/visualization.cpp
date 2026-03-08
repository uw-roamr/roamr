#include "visualization.h"
#include "map_api.h"

#include <condition_variable>
#include <mutex>
#include <stdint.h>

namespace mapping {
namespace visualization {

static std::mutex               g_render_mutex;
static std::condition_variable  g_render_cv;
static MapRenderRequest         g_pending_request{};
static bool                     g_has_request = false;

void request_render(const MapRenderRequest& req) {
    {
        std::lock_guard<std::mutex> lk(g_render_mutex);
        g_pending_request = req;
        g_has_request = true;
    }
    g_render_cv.notify_one();
}

void wait_and_render(MapFrame& out_frame) {
    MapRenderRequest req;
    {
        std::unique_lock<std::mutex> lk(g_render_mutex);
        g_render_cv.wait(lk, []{ return g_has_request; });
        req = g_pending_request;
        g_has_request = false;
    }
    render_map_frame(
        req.pose_count,
        req.point_count,
        req.width,
        req.height,
        req.timestamp,
        out_frame);
}

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
