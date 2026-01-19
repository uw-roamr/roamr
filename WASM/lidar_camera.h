#pragma once
#include "wasm_utils.h"
#include <stddef.h> // size_t
#include <stdint.h> // uint8_t
#include <array>

// time synchronized LiDAR points and camera image

struct CameraConfig {
  double timestamp;

  int image_width;
  int image_height;
  int image_channels;
};

constexpr int max_points_per_scan = 100000;
constexpr int float_per_point = 3;
constexpr size_t max_points_size = static_cast<size_t>(max_points_per_scan * float_per_point);

constexpr int max_image_height = 1440;
constexpr int max_image_width = 1920;
constexpr int max_image_channels = 3;
constexpr size_t max_image_size = static_cast<size_t> (max_image_width * max_image_height * max_image_channels);

struct LidarCameraData {
  double timestamp;

  std::array<float, max_points_size> points;
  size_t points_size;

  std::array<float, max_image_size> image;
  size_t image_size;
};

WASM_IMPORT("host", "init_camera") void init_camera(CameraConfig *config);
WASM_IMPORT("host", "read_lidar_camera") void read_lidar_camera(LidarCameraData *data);

constexpr double LidarCameraRefreshHz = 30.0;
constexpr int LidarCameraIntervalMs = static_cast<int>(1000.0 / LidarCameraRefreshHz);
