#include "mapping/visualization.h"
#include "mapping/costmap.h"
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
static std::array<uint8_t, kMaxPixels * 4> s_base_image_buf{};
static int32_t s_cur_w = 0;
static int32_t s_cur_h = 0;
static uint64_t s_cached_map_revision = 0;
static uint64_t s_cached_path_hash = 0;
static int32_t s_cached_w = 0;
static int32_t s_cached_h = 0;
static bool s_have_cached_base = false;

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
    if (overlay.path_grid.empty() &&
        !overlay.goal_enabled &&
        overlay.frontier_candidates.empty() &&
        overlay.selected_frontier_cluster.empty() &&
        !overlay.selected_frontier_seed_enabled) return;

    for (const planning::GridCoord& cell : overlay.frontier_candidates) {
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
        paint_pixel(ppx, ppy, 0, 255, 180, 255, painted); // aqua frontier candidates
    }

    for (const planning::GridCoord& cell : overlay.selected_frontier_cluster) {
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
        paint_pixel(ppx, ppy, 255, 0, 220, 255, painted); // magenta selected cluster
    }

    int32_t prev_ppx = 0;
    int32_t prev_ppy = 0;
    bool have_prev_path_pixel = false;
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
        if (have_prev_path_pixel) {
            draw_line(prev_ppx, prev_ppy, ppx, ppy, 0, 150, 255, 255, painted);
        }
        paint_pixel(ppx, ppy, 0, 150, 255, 255, painted); // blue path
        prev_ppx = ppx;
        prev_ppy = ppy;
        have_prev_path_pixel = true;
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

    if (overlay.selected_frontier_seed_enabled) {
        int32_t ppx = 0, ppy = 0;
        if (snapshot_grid_to_pixel(
                snapshot.meta,
                overlay.selected_frontier_seed.x,
                overlay.selected_frontier_seed.y,
                s_cur_w,
                s_cur_h,
                scale,
                off_x,
                off_y,
                &ppx,
                &ppy)) {
            for (int32_t dy = -1; dy <= 1; ++dy) {
                for (int32_t dx = -1; dx <= 1; ++dx) {
                    paint_pixel(ppx + dx, ppy + dy, 255, 80, 0, 255, painted); // orange seed
                }
            }
        }
    }
}

void draw_map_layer(
    const MapSnapshot& snapshot,
    const InflatedCostmap* costmap,
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
            uint8_t g = 128;
            uint8_t b = 128;
            if (gx >= 0 && gx < snapshot.meta.width &&
                gy >= 0 && gy < snapshot.meta.height) {
                const int32_t cell = gx + gy * snapshot.meta.width;
                const int8_t occ = snapshot.occupancy[static_cast<size_t>(cell)];
                if (occ >= 0) {
                    if (costmap &&
                        costmap->valid() &&
                        costmap->is_inflated_blocked(gx, gy) &&
                        !costmap->is_source_occupied(gx, gy)) {
                        v = 210;
                        g = 140;
                        b = 140;
                    } else {
                        v = occ >= 50 ? 255 : 0;
                        g = v;
                        b = v;
                    }
                }
            }
            const int32_t off = (py * s_cur_w + px) * 4;
            s_image_buf[off + 0] = v;
            s_image_buf[off + 1] = g;
            s_image_buf[off + 2] = b;
            s_image_buf[off + 3] = 255;
        }
    }
}

uint64_t overlay_path_hash(const planning::bridge::PlanningOverlay& overlay) {
    uint64_t h = 1469598103934665603ull;
    const auto mix = [&h](uint64_t v) {
        h ^= v;
        h *= 1099511628211ull;
    };
    mix(static_cast<uint64_t>(overlay.goal_enabled ? 1 : 0));
    mix(static_cast<uint64_t>(static_cast<uint32_t>(overlay.goal_cell.x)));
    mix(static_cast<uint64_t>(static_cast<uint32_t>(overlay.goal_cell.y)));
    mix(static_cast<uint64_t>(overlay.path_grid.size()));
    for (const planning::GridCoord& cell : overlay.path_grid) {
        mix(static_cast<uint64_t>(static_cast<uint32_t>(cell.x)));
        mix(static_cast<uint64_t>(static_cast<uint32_t>(cell.y)));
    }
    mix(static_cast<uint64_t>(overlay.frontier_candidates.size()));
    for (const planning::GridCoord& cell : overlay.frontier_candidates) {
        mix(static_cast<uint64_t>(static_cast<uint32_t>(cell.x)));
        mix(static_cast<uint64_t>(static_cast<uint32_t>(cell.y)));
    }
    mix(static_cast<uint64_t>(overlay.selected_frontier_cluster.size()));
    for (const planning::GridCoord& cell : overlay.selected_frontier_cluster) {
        mix(static_cast<uint64_t>(static_cast<uint32_t>(cell.x)));
        mix(static_cast<uint64_t>(static_cast<uint32_t>(cell.y)));
    }
    mix(static_cast<uint64_t>(overlay.selected_frontier_seed_enabled ? 1 : 0));
    mix(static_cast<uint64_t>(static_cast<uint32_t>(overlay.selected_frontier_seed.x)));
    mix(static_cast<uint64_t>(static_cast<uint32_t>(overlay.selected_frontier_seed.y)));
    return h;
}

void render_base_layers(
    const MapSnapshot& snapshot,
    const planning::bridge::PlanningOverlay& overlay,
    float scale, float off_x, float off_y) {
    InflatedCostmap costmap;
    const InflatedCostmap* costmap_ptr =
        build_inflated_costmap(
            snapshot,
            default_navigation_costmap_config(),
            &costmap) ? &costmap : nullptr;
    static std::array<uint8_t, kMaxPixels> s_painted;
    std::fill_n(s_painted.begin(), s_cur_w * s_cur_h, static_cast<uint8_t>(0));
    draw_path_layer(snapshot, overlay, scale, off_x, off_y, s_painted);
    draw_map_layer(snapshot, costmap_ptr, scale, off_x, off_y, s_painted);
    std::memcpy(
        s_base_image_buf.data(),
        s_image_buf.data(),
        static_cast<size_t>(s_cur_w * s_cur_h * 4));
    s_cached_map_revision = snapshot.map_revision;
    s_cached_path_hash = overlay_path_hash(overlay);
    s_cached_w = s_cur_w;
    s_cached_h = s_cur_h;
    s_have_cached_base = true;
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
    const uint64_t path_hash = overlay_path_hash(overlay);
    if (!s_have_cached_base ||
        s_cached_w != s_cur_w ||
        s_cached_h != s_cur_h ||
        s_cached_map_revision != snapshot.map_revision ||
        s_cached_path_hash != path_hash) {
        render_base_layers(snapshot, overlay, scale, off_x, off_y);
    }

    std::memcpy(
        s_image_buf.data(),
        s_base_image_buf.data(),
        static_cast<size_t>(s_cur_w * s_cur_h * 4));

    static std::array<uint8_t, kMaxPixels> s_painted;
    std::fill_n(s_painted.begin(), s_cur_w * s_cur_h, static_cast<uint8_t>(0));
    draw_pose_layer(snapshot, pose_trail, scale, off_x, off_y, s_painted); // Pose only

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
