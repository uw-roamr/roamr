#include "mapping/visualization.h"
#include "mapping/map.h"
#include "core/pose/se2.h"
#include "core/telemetry.h"

#include <array>
#include <cmath>
#include <cstring>
#include <stdint.h>

namespace mapping {
namespace visualization {

namespace {

constexpr int32_t kMaxPixels = Map::kMaxImageWidth * Map::kMaxImageHeight;
constexpr int32_t kPoseLineLength = 10; // pixels for x and y axes

static std::array<uint8_t, kMaxPixels * 4> s_image_buf{};
static int32_t s_cur_w = 0;
static int32_t s_cur_h = 0;

inline void paint_pixel(
    int32_t x, int32_t y,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a,
    std::array<uint8_t, kMaxPixels>& painted)
{
    if (x < 0 || x >= s_cur_w || y < 0 || y >= s_cur_h) return;
    const int32_t idx = y * s_cur_w + x;
    if (painted[idx]) return;
    const int32_t off = idx * 4;
    s_image_buf[off + 0] = r;
    s_image_buf[off + 1] = g;
    s_image_buf[off + 2] = b;
    s_image_buf[off + 3] = a;
    painted[idx] = 1;
}

void draw_line(
    int32_t x0, int32_t y0, int32_t x1, int32_t y1,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a,
    std::array<uint8_t, kMaxPixels>& painted)
{
    int dx =  (x1 > x0) ? (x1 - x0) : (x0 - x1);
    int sx = (x0 < x1) ? 1 : -1;
    int dy = -((y1 > y0) ? (y1 - y0) : (y0 - y1));
    int sy = (y0 < y1) ? 1 : -1;
    int err = dx + dy;
    int x = x0, y = y0;
    for (;;) {
        paint_pixel(x, y, r, g, b, a, painted);
        if (x == x1 && y == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x += sx; }
        if (e2 <= dx) { err += dx; y += sy; }
    }
}

// red forward, green left (FLU convention)
void draw_pose_layer(
    const Map& map, int32_t pose_count,
    float scale, float off_x, float off_y,
    std::array<uint8_t, kMaxPixels>& painted)
{
    if (pose_count <= 0) return;

    const core::PoseSE2d& pose = map.get_pose_data()[pose_count - 1];
    const double wx    = pose.x;
    const double wy    = pose.y;
    const double theta = pose.theta;

    int32_t gx = 0, gy = 0;
    if (!map.world_to_grid(wx, wy, &gx, &gy)) return;

    int32_t ppx = 0, ppy = 0;
    if (!map.grid_to_pixel(gx, gy, s_cur_w, s_cur_h, scale, off_x, off_y, &ppx, &ppy)) return;

    const double c = std::cos(theta);
    const double s = std::sin(theta);

    const int32_t fwd_x1  = ppx + static_cast<int32_t>( c * kPoseLineLength);
    const int32_t fwd_y1  = ppy + static_cast<int32_t>(-s * kPoseLineLength);
    const int32_t left_x1 = ppx + static_cast<int32_t>(-s * kPoseLineLength);
    const int32_t left_y1 = ppy + static_cast<int32_t>(-c * kPoseLineLength);

    draw_line(ppx, ppy, fwd_x1,  fwd_y1,  255,   0, 0, 255, painted); // red   = forward
    draw_line(ppx, ppy, left_x1, left_y1,   0, 255, 0, 255, painted); // green = left
}

void draw_path_layer(
    const Map& map,
    float scale, float off_x, float off_y,
    std::array<uint8_t, kMaxPixels>& painted)
{
    const int32_t path_count = map.get_planned_path_count();
    if (path_count <= 0 && !map.get_planned_goal_enabled()) return;

    const int32_t* path = map.get_planned_path_data();

    for (int32_t i = 0; i < path_count; ++i) {
        const int32_t gx = path[i * 2 + 0];
        const int32_t gy = path[i * 2 + 1];
        int32_t ppx = 0, ppy = 0;
        if (!map.grid_to_pixel(gx, gy, s_cur_w, s_cur_h, scale, off_x, off_y, &ppx, &ppy)) continue;
        paint_pixel(ppx, ppy, 0, 150, 255, 255, painted); // blue path
    }

    if (map.get_planned_goal_enabled()) {
        int32_t ppx = 0, ppy = 0;
        if (map.grid_to_pixel(
                map.get_planned_goal_x(), map.get_planned_goal_y(),
                s_cur_w, s_cur_h, scale, off_x, off_y, &ppx, &ppy)) {
            for (int32_t dy = -2; dy <= 2; ++dy) {
                for (int32_t dx = -2; dx <= 2; ++dx) {
                    paint_pixel(ppx + dx, ppy + dy, 255, 200, 0, 255, painted); // yellow goal
                }
            }
        }
    }
}

void draw_map_layer(
    const Map& map,
    float scale, float off_x, float off_y,
    std::array<uint8_t, kMaxPixels>& painted)
{
    const uint8_t* visited   = map.get_visited_data();
    const uint8_t* confirmed = map.get_confirmed_data();

    for (int32_t py = 0; py < s_cur_h; ++py) {
        for (int32_t px = 0; px < s_cur_w; ++px) {
            if (painted[py * s_cur_w + px]) continue;

            const int32_t gx = static_cast<int32_t>(
                (static_cast<float>(px) - off_x) / scale);
            const int32_t gy = Map::kMapSizeY - 1 - static_cast<int32_t>(
                (static_cast<float>(py) - off_y) / scale);

            uint8_t v = 128; // unknown (gray)
            if (gx >= 0 && gx < Map::kMapSizeX && gy >= 0 && gy < Map::kMapSizeY) {
                const int32_t cell = gx + gy * Map::kMapSizeX;
                if (visited[cell]) {
                    v = confirmed[cell] ? 255 : 0;
                }
            }
            const int32_t off = (py * s_cur_w + px) * 4;
            s_image_buf[off + 0] = v;
            s_image_buf[off + 1] = v;
            s_image_buf[off + 2] = v;
            s_image_buf[off + 3] = 255;
        }
    }
}

}

void render_map_frame(
    const Map&  map,
    int32_t     pose_count,
    int32_t     width,
    int32_t     height,
    double      timestamp,
    MapImage& out_frame)
{
    wasm_log_line("drawing map");
    // Clamp image dimensions and store in visualization state.
    if (width  <= 0) width  = 256;
    if (height <= 0) height = 256;
    if (width  > Map::kMaxImageWidth)  width  = Map::kMaxImageWidth;
    if (height > Map::kMaxImageHeight) height = Map::kMaxImageHeight;
    s_cur_w = width;
    s_cur_h = height;

    float scale = 1.0f, off_x = 0.0f, off_y = 0.0f;
    Map::compute_viewport(s_cur_w, s_cur_h, scale, off_x, off_y);

    // One byte per pixel — 0 = unclaimed, 1 = claimed by a higher-priority layer.
    static std::array<uint8_t, kMaxPixels> s_painted;
    std::fill_n(s_painted.begin(), s_cur_w * s_cur_h, static_cast<uint8_t>(0));

    draw_pose_layer(map, pose_count, scale, off_x, off_y, s_painted); // Layer 1
    draw_path_layer(map,             scale, off_x, off_y, s_painted); // Layer 2
    draw_map_layer( map,             scale, off_x, off_y, s_painted); // Layer 3 (base)

    out_frame.timestamp = timestamp;
    out_frame.width     = s_cur_w;
    out_frame.height    = s_cur_h;
    out_frame.channels  = 4;
    out_frame.data_ptr  = static_cast<uint32_t>(
        reinterpret_cast<uintptr_t>(s_image_buf.data()));
    out_frame.data_size = static_cast<uint32_t>(s_cur_w * s_cur_h * 4);

    rerun_log_map_frame(&out_frame);
}

} // namespace visualization
} // namespace mapping
