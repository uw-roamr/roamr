#pragma once
#include <array>
#include <cstdint>

#include "mapping/map_metadata.h"
#include "core/pose/se2.h"

namespace mapping{

    constexpr int kMaxMapPoints = 20000;
    constexpr int kMaxFreeRays  = kMaxMapPoints;
    class Map{
      public:
        static constexpr int32_t kMaxImageWidth = 512;
        static constexpr int32_t kMaxImageHeight = 512;

        // Map parameters (mirroring the ROS node)
        static constexpr float kGridResolution = 0.02f; // meters
        static constexpr int32_t kMapSizeX = 400;
        static constexpr int32_t kMapSizeY = 400;
        static constexpr int16_t kMinCellScore = -16;
        static constexpr int16_t kMaxCellScore = 16;
        static constexpr int16_t kHitIncrement = 4;
        static constexpr int16_t kFreeDecrement = 1;
        static constexpr int16_t kOccupiedThreshold = 4;
        static constexpr int16_t kClearThreshold = 0;
        static constexpr float kMinRange = 0.1f; // meters

        void reset_points();
        void reset_map();
        int32_t get_occupancy_grid(int8_t* out_data, int32_t max_cells) const;
        int32_t get_occupancy_meta(OccupancyGridMetadata* out_meta) const;
        void set_points_world(int32_t in_world);
        void set_point(int32_t idx, double x, double y);
        void set_free_point(int32_t idx, double x, double y);
        void reset_free_points();
        // Integrate the latest scan into the occupancy grid.
        int32_t world_to_grid(double x, double y, int32_t* gx, int32_t* gy) const;
        bool begin_scan_integration(
            const core::PoseSE2d& pose,
            int32_t* start_x,
            int32_t* start_y);
        void integrate_hit_world(
            int32_t start_x,
            int32_t start_y,
            const core::PoseSE2d& pose,
            double wx,
            double wy);
        void integrate_free_world(
            int32_t start_x,
            int32_t start_y,
            double wx,
            double wy);
        void draw_map(
            const core::PoseSE2d& pose,
            int32_t point_count,
            int32_t free_point_count);

      private:
        static int32_t is_finite(float v);

        int32_t grid_index(int32_t gx, int32_t gy) const;
        void maybe_init_origin(double x, double y);
        void integrate_ray(int32_t x0, int32_t y0, int32_t x1, int32_t y1);
        void integrate_scan(
            const core::PoseSE2d& pose,
            int32_t point_count,
            int32_t points_in_world);
        // Cast a free-space-only ray: marks cells as visited/decayed but does
        // not register an occupancy hit at the endpoint.
        void integrate_free_ray(int32_t x0, int32_t y0, int32_t x1, int32_t y1);
        void integrate_free_scan(const core::PoseSE2d& pose, int32_t free_point_count);

        // LiDAR points storage (2D projection x,y).
        std::array<float, 2 * kMaxMapPoints> points_{};
        int32_t points_count_ = 0;

        // Free-space ray endpoints (world frame, clipped to max range).
        std::array<float, 2 * kMaxFreeRays> free_points_{};
        int32_t free_points_count_ = 0;

        // Map state.
        std::array<int16_t, kMapSizeX * kMapSizeY> scan_count_{};
        std::array<uint8_t, kMapSizeX * kMapSizeY> confirmed_{};
        std::array<uint8_t, kMapSizeX * kMapSizeY> visited_{};
        std::array<uint32_t, kMapSizeX * kMapSizeY> hit_cell_scan_stamp_{};
        uint32_t current_scan_stamp_ = 0;

        int32_t map_origin_initialized_ = 0;
        float map_origin_offset_x_ = 0.0f;
        float map_origin_offset_y_ = 0.0f;

        // 0 = points are in robot/laser frame (default), 1 = points already in world/map frame.
        int32_t points_in_world_ = 0;
    };
  WASM_IMPORT("host", "rerun_log_map_frame") void rerun_log_map_frame(const MapImage *frame);
};
