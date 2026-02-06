#pragma once
#include <stdint.h>
#include "wasm_utils.h"

extern "C" {

struct MapFrame {
  double timestamp;
  int32_t width;
  int32_t height;
  int32_t channels;
  uint32_t data_ptr;
  int32_t data_size;
};

WASM_IMPORT("host", "rerun_log_map_frame") void rerun_log_map_frame(const MapFrame *frame);

void reset_map();
void reset_points();
void reset_poses();
void set_points_world(int32_t in_world);
void set_pose(int32_t idx, float x, float y, float theta);
void set_point(int32_t idx, float x, float y);
void draw_map(int32_t poseCount, int32_t pointCount, int32_t width, int32_t height);
int32_t get_image_width();
int32_t get_image_height();
uint8_t *get_image_rgba_ptr();
int32_t get_image_rgba_size();

} // extern "C"
