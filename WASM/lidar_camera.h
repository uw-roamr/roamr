#pragma once
#include "wasm_utils.h"
#include <stddef.h> // size_t
#include <stdint.h> // uint8_t

// synchronized LiDAR points and camera image
// todo: double buffering
struct LidarCameraData {
  double timestamp;

  const float *depth_map;
  int depth_width;
  int depth_height;

  const uint8_t *image;
  int image_width;
  int image_height;
  int image_channels;
};

WASM_IMPORT("host", "read_lidar_camera") void read_lidar_camera(LidarCameraData *data);

constexpr double LidarCameraRefreshHz = 30.0;
constexpr int LidarCameraIntervalMs = static_cast<int>(1000.0 / LidarCameraRefreshHz);
