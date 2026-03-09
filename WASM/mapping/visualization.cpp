#include "mapping/visualization.h"
#include "mapping/map.h"
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
    const MapSnapshot& snapshot,
    const PoseTrailState& pose_trail,
    float scale, float off_x, float off_y,
    std::array<uint8_t, kMaxPixels>& painted)
{
    for (size_t i = 1; i < pose_trail.poses.size(); ++i) {
        int32_t gx0 = 0;
        int32_t gy0 = 0;
        int32_t gx1 = 0;
        int32_t gy1 = 0;
        const core::PoseSE2d& a = pose_trail.poses[i - 1];
        const core::PoseSE2d& b = pose_trail.poses[i];
        const int32_t iax = static_cast<int32_t>(
            std::floor((a.x - snapshot.meta.origin_x_m) / snapshot.meta.resolution_m));
        const int32_t iay = static_cast<int32_t>(
            std::floor((a.y - snapshot.meta.origin_y_m) / snapshot.meta.resolution_m));
        const int32_t ibx = static_cast<int32_t>(
            std::floor((b.x - snapshot.meta.origin_x_m) / snapshot.meta.resolution_m));
        const int32_t iby = static_cast<int32_t>(
            std::floor((b.y - snapshot.meta.origin_y_m) / snapshot.meta.resolution_m));
        gx0 = iax;
        gy0 = iay;
        gx1 = ibx;
        gy1 = iby;
        int32_t px0 = 0;
        int32_t py0 = 0;
        int32_t px1 = 0;
        int32_t py1 = 0;
        if (!snapshot_grid_to_pixel(
                snapshot.meta, gx0, gy0, s_cur_w, s_cur_h, scale, off_x, off_y, &px0, &py0) ||
            !snapshot_grid_to_pixel(
                snapshot.meta, gx1, gy1, s_cur_w, s_cur_h, scale, off_x, off_y, &px1, &py1)) {
            continue;
        }
        draw_line(px0, py0, px1, py1, 80, 0, 128, 255, painted);
    }

    const core::PoseSE2d& pose = snapshot.pose;
    const double wx    = pose.x;
    const double wy    = pose.y;
    const double theta = pose.theta;

    const int32_t gx = static_cast<int32_t>(
        std::floor((wx - snapshot.meta.origin_x_m) / snapshot.meta.resolution_m));
    const int32_t gy = static_cast<int32_t>(
        std::floor((wy - snapshot.meta.origin_y_m) / snapshot.meta.resolution_m));
    if (gx < 0 || gx >= snapshot.meta.width || gy < 0 || gy >= snapshot.meta.height) return;

    int32_t ppx = 0, ppy = 0;
    if (!snapshot_grid_to_pixel(
            snapshot.meta, gx, gy, s_cur_w, s_cur_h, scale, off_x, off_y, &ppx, &ppy)) return;

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
    const MapSnapshot& snapshot,
    const planning::bridge::PlanningOverlay& overlay,
    float scale, float off_x, float off_y,
    std::array<uint8_t, kMaxPixels>& painted)
{
    if (overlay.path_grid.empty() && !overlay.goal_enabled) return;

    for (const planning::GridCoord& cell : overlay.path_grid) {
        int32_t ppx = 0, ppy = 0;
        if (!snapshot_grid_to_pixel(
                snapshot.meta,
                cell.x,
                cell.y,
                s_cur_w,
                s_cur_h,
                scale,
                off_x,
                off_y,
                &ppx,
                &ppy)) continue;
        paint_pixel(ppx, ppy, 0, 150, 255, 255, painted); // blue path
    }

    if (overlay.goal_enabled) {
        int32_t ppx = 0, ppy = 0;
        if (snapshot_grid_to_pixel(
                snapshot.meta,
                overlay.goal_cell.x,
                overlay.goal_cell.y,
                s_cur_w,
                s_cur_h,
                scale,
                off_x,
                off_y,
                &ppx,
                &ppy)) {
            for (int32_t dy = -2; dy <= 2; ++dy) {
                for (int32_t dx = -2; dx <= 2; ++dx) {
                    paint_pixel(ppx + dx, ppy + dy, 255, 200, 0, 255, painted); // yellow goal
                }
            }
        }
    }
}

void draw_map_layer(
    const MapSnapshot& snapshot,
    float scale, float off_x, float off_y,
    std::array<uint8_t, kMaxPixels>& painted)
{
    for (int32_t py = 0; py < s_cur_h; ++py) {
        for (int32_t px = 0; px < s_cur_w; ++px) {
            if (painted[py * s_cur_w + px]) continue;

            const int32_t gx = static_cast<int32_t>(
                (static_cast<float>(px) - off_x) / scale);
            const int32_t gy = snapshot.meta.height - 1 - static_cast<int32_t>(
                (static_cast<float>(py) - off_y) / scale);

            uint8_t v = 128; // unknown (gray)
            if (gx >= 0 && gx < snapshot.meta.width &&
                gy >= 0 && gy < snapshot.meta.height) {
                const int32_t cell = gx + gy * snapshot.meta.width;
                const int8_t occ = snapshot.occupancy[static_cast<size_t>(cell)];
                if (occ >= 0) {
                    v = occ >= 50 ? 255 : 0;
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
    const MapSnapshot& snapshot,
    const PoseTrailState& pose_trail,
    const planning::bridge::PlanningOverlay& overlay,
    int32_t width,
    int32_t height,
    MapImage& out_frame)
{
    if (!snapshot.valid()) return;
    // Clamp image dimensions and store in visualization state.
    if (width  <= 0) width  = 256;
    if (height <= 0) height = 256;
    if (width  > Map::kMaxImageWidth)  width  = Map::kMaxImageWidth;
    if (height > Map::kMaxImageHeight) height = Map::kMaxImageHeight;
    s_cur_w = width;
    s_cur_h = height;

    float scale = 1.0f, off_x = 0.0f, off_y = 0.0f;
    compute_snapshot_viewport(snapshot.meta, s_cur_w, s_cur_h, &scale, &off_x, &off_y);

    // One byte per pixel — 0 = unclaimed, 1 = claimed by a higher-priority layer.
    static std::array<uint8_t, kMaxPixels> s_painted;
    std::fill_n(s_painted.begin(), s_cur_w * s_cur_h, static_cast<uint8_t>(0));

    draw_pose_layer(snapshot, pose_trail, scale, off_x, off_y, s_painted); // Layer 1
    draw_path_layer(snapshot, overlay, scale, off_x, off_y, s_painted); // Layer 2
    draw_map_layer(snapshot, scale, off_x, off_y, s_painted); // Layer 3 (base)

    out_frame.timestamp = snapshot.timestamp;
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
