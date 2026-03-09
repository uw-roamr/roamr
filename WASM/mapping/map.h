#pragma once
#include <array>
#include <cstdint>

#include "mapping/map_api.h"

namespace mapping{

    constexpr int kMaxMapPoints = 20000;
    constexpr int kMaxMapPoses = 4096;

    class Map{
      public:
        static constexpr int32_t kMaxImageWidth = 512;
        static constexpr int32_t kMaxImageHeight = 512;
        static constexpr int32_t kMaxPlannedPath = kMaxMapPoses;

        // Map parameters (mirroring the ROS node)
        static constexpr float kGridResolution = 0.02f; // meters
        static constexpr int32_t kMapSizeX = 400;
        static constexpr int32_t kMapSizeY = 400;
        static constexpr int32_t kScanThreshold = 5;
        static constexpr int32_t kDecayFactor = 10;
        static constexpr int32_t kClearThreshold = 1; // clear confirmed cells after enough free-space passes
        static constexpr float kMinRange = 0.1f; // meters

        void reset_poses();
        void reset_points();
        void reset_map();
        int32_t get_occupancy_grid(int8_t* out_data, int32_t max_cells) const;
        int32_t get_occupancy_meta(OccupancyGridMetadata* out_meta) const;
        void clear_planned_path();
        void set_planned_path_cell(int32_t idx, int32_t gx, int32_t gy);
        void set_planned_goal_cell(int32_t gx, int32_t gy, int32_t enabled);
        void set_points_world(int32_t in_world);
        void set_pose(int32_t idx, double x, double y, double theta);
        void set_point(int32_t idx, double x, double y);
        void draw_map(int32_t pose_count, int32_t point_count, int32_t width, int32_t height);
        int32_t get_image_width() const;
        int32_t get_image_height() const;
        uint8_t* get_image_rgba_ptr();
        int32_t get_image_rgba_size() const;
        int32_t get_image_pixel_u32(int32_t index) const;

      private:
        static int32_t is_finite(float v);

        int32_t grid_index(int32_t gx, int32_t gy) const;
        int32_t world_to_grid(double x, double y, int32_t* gx, int32_t* gy) const;
        void maybe_init_origin(double x, double y);
        void integrate_ray(int32_t x0, int32_t y0, int32_t x1, int32_t y1);
        void integrate_scan(
            double pose_x,
            double pose_y,
            double pose_theta,
            int32_t point_count,
            int32_t points_in_world);
        void set_pixel(int32_t x, int32_t y, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
        int32_t grid_to_pixel(
            int32_t gx,
            int32_t gy,
            float scale,
            float off_x,
            float off_y,
            int32_t* px,
            int32_t* py) const;

        // Pose storage for drawing trajectory.
        std::array<double, 3 * kMaxMapPoses> poses_{}; // x,y,theta triples

        // Image buffer (RGBA8888).
        std::array<uint8_t, kMaxImageWidth * kMaxImageHeight * 4> image_{};
        int32_t cur_w_ = 256;
        int32_t cur_h_ = 256;

        // LiDAR points storage (2D projection x,y).
        std::array<float, 2 * kMaxMapPoints> points_{};
        int32_t points_count_ = 0;

        // Planned path storage (grid cells in map coordinates).
        std::array<int32_t, 2 * kMaxPlannedPath> planned_path_{};
        int32_t planned_path_count_ = 0;
        int32_t planned_goal_enabled_ = 0;
        int32_t planned_goal_x_ = 0;
        int32_t planned_goal_y_ = 0;

        // Map state.
        std::array<int16_t, kMapSizeX * kMapSizeY> scan_count_{};
        std::array<uint8_t, kMapSizeX * kMapSizeY> confirmed_{};
        std::array<uint8_t, kMapSizeX * kMapSizeY> visited_{};

        int32_t map_origin_initialized_ = 0;
        float map_origin_offset_x_ = 0.0f;
        float map_origin_offset_y_ = 0.0f;

        // 0 = points are in robot/laser frame (default), 1 = points already in world/map frame.
        int32_t points_in_world_ = 0;
    };


  constexpr double mapMinIntervalSeconds = 0.1; // seconds
  WASM_IMPORT("host", "rerun_log_map_frame") void rerun_log_map_frame(const MapFrameMetadata *frame);
};
