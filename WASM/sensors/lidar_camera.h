#pragma once
#include "core/pose/coordinate_frames.h"
#include "wasm_utils.h"
#include <stddef.h> // size_t
#include <stdint.h> // uint8_t
#include <array>

// time synchronized LiDAR points and camera image

namespace sensors{

  struct CameraConfig {
    double timestamp;

    int image_width;
    int image_height;
    int image_channels;
  };

  constexpr int max_points_per_scan = 100000;
  constexpr int float_per_point = 3;
  constexpr size_t max_points_size = static_cast<size_t>(max_points_per_scan * float_per_point);
  constexpr int colors_per_point = 3;
  constexpr size_t max_colors_size = static_cast<size_t>(max_points_per_scan * colors_per_point);

  constexpr int max_image_height = 1440;
  constexpr int max_image_width = 1920;
  constexpr int max_image_channels = 3;
  constexpr size_t max_image_size = static_cast<size_t> (max_image_width * max_image_height * max_image_channels);

  struct LidarCameraData {
    double timestamp;

    std::array<float, max_points_size> points;
    size_t points_size;

    std::array<uint8_t, max_colors_size> colors; // RGB per point
    size_t colors_size;

    std::array<uint8_t, max_image_size> image;
    size_t image_size;

    core::CoordinateFrameId_t points_frame_id; // CoordinateFrameId
    core::CoordinateFrameId_t image_frame_id;  // CoordinateFrameId
  };

  // assumes RDF -> FLU
  inline void ensure_points_flu(LidarCameraData& data) noexcept {
    const auto flu = static_cast<core::CoordinateFrameId_t>(core::CoordinateFrameId::kFLU);
    if (data.points_frame_id == flu) {
      return;
    }
    const int total_points = static_cast<int>(data.points_size / 3);
    for (int i = 0; i < total_points; ++i) {
      const int base = i * 3;
      float x = data.points[base + 0];
      float y = data.points[base + 1];
      float z = data.points[base + 2];
      core::rdf_to_flu(x, y, z, &x, &y, &z);
      data.points[base + 0] = x;
      data.points[base + 1] = y;
      data.points[base + 2] = z;
    }
    data.points_frame_id = static_cast<core::CoordinateFrameId_t>(core::CoordinateFrameId::kFLU);
  }

  WASM_IMPORT("host", "init_camera") void init_camera(CameraConfig *config);
  WASM_IMPORT("host", "read_lidar_camera") void read_lidar_camera(LidarCameraData *data);

  constexpr double LidarCameraRefreshHz = 10.0;
  constexpr int LidarCameraIntervalMs = static_cast<int>(1000.0 / (LidarCameraRefreshHz * 2.1));
}; //namespace sensors
