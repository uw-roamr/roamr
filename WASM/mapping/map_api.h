#pragma once
#include <stdint.h>
#include "wasm_utils.h"


namespace mapping{
  constexpr int mapMaxPoints = 20000;
  constexpr int kMapMaxPoses = 4096;

  struct MapFrame {
    double timestamp;
    int32_t width;
    int32_t height;
    int32_t channels;
    uint32_t data_ptr;
    int32_t data_size;
  };

  struct OccupancyGridMeta {
    int32_t width;
    int32_t height;
    double resolution_m;
    double origin_x_m;
    double origin_y_m;
    int32_t origin_initialized;
  };

  constexpr double mapMinIntervalSeconds = 0.1; // seconds


  WASM_IMPORT("host", "rerun_log_map_frame") void rerun_log_map_frame(const MapFrame *frame);

  void reset_map();
  void reset_points();
  void reset_poses();
  void set_points_world(int32_t in_world);
  void set_pose(int32_t idx, double x, double y, double theta);
  void set_point(int32_t idx, double x, double y);
  int32_t get_occupancy_grid(int8_t* out_data, int32_t max_cells);
  int32_t get_occupancy_meta(OccupancyGridMeta* out_meta);
  void clear_planned_path();
  void set_planned_path_cell(int32_t idx, int32_t gx, int32_t gy);
  void set_planned_goal_cell(int32_t gx, int32_t gy, int32_t enabled);
  void draw_map(int32_t poseCount, int32_t pointCount, int32_t width, int32_t height);
  int32_t get_image_width();
  int32_t get_image_height();
  uint8_t *get_image_rgba_ptr();
  int32_t get_image_rgba_size();
}; //namespace mapping
