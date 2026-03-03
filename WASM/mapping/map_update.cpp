#include "map_update.h"

#include "map_api.h"

#include <algorithm>
#include <cmath>
#include <iostream>

namespace mapping {
  constexpr int mapWidth = 256;
  constexpr int mapHeight = 256;
  constexpr int mapMaxPoints = 20000; // keep in sync with map.cpp
  constexpr float mapMaxRangeMeters = 1.8f;
  constexpr float mapMinZ = 0.0f; // drop ground (world Z up)
  constexpr float mapMaxZ = 0.15f; // drop ceiling/background
  // Sensor height above world origin (meters). Use to convert sensor-relative Z to world Z.
  constexpr float sensorHeightMeters = 0.20f;

  // Rerun logging: include camera image in the filtered lidar frame (expensive copy).
  constexpr bool kRerunIncludeImage = false;
  // Rerun logging: highlight filtered points in bright pink.
  constexpr bool kRerunHighlightFiltered = true;
  constexpr double kMapLogIntervalSec = 0.1;


  static double g_last_yaw_log_ts = -1.0;
  static double g_last_map_log_ts = -1.0;


  void update_map_from_lidar(const sensors::LidarCameraData& lc_data,
                             MapFrame& map_frame,
                             sensors::LidarCameraData* rerun_out,
                             bool update_map,
                             bool& map_initialized,
                             const core::Vector4d& q_body_to_world_in
                            //  const core::PoseSE3d& pose,
                            //  const bool rotation_only_bc_imu_drifts
                            ) {
    const int total_points = static_cast<int>(lc_data.points_size / 3);
    if (total_points <= 0) return;

    if (update_map && !map_initialized) {
      reset_map();
      reset_points();
      reset_poses();
      set_points_world(1);
      set_pose(0, 0.0f, 0.0f, 0.0f);
      map_initialized = true;
    }

    const core::Vector4d q_body_to_world = core::quat_normalize(q_body_to_world_in);
    const bool points_rdf =
        lc_data.points_frame_id == static_cast<core::CoordinateFrameId_t>(core::CoordinateFrameId::kRDF);

    // Use the phone-facing axis (camera forward) as +X for mapping.
    const core::Vector3d forward_flu = {1.0, 0.0, 0.0};

    // currently, this does nothing so we can comment it out safely. in the future, we may want to compensate for mounting errors.
    const core::Vector4d q_point_to_body = core::quat_identity();
    const core::Vector3d forward_flu_body = core::quat_rotate(q_point_to_body, forward_flu);

    const core::Vector3d forward_flu_world = core::quat_rotate(q_body_to_world, forward_flu_body);
    const core::Vector3d& ffw = forward_flu_world;

    // project to SE2
    const double yaw = std::atan2(ffw.y, ffw.x);
    const double range = std::sqrt(ffw.x * ffw.x + ffw.y * ffw.y);
    set_pose(0, 0.0f, 0.0f, yaw);


    const core::Vector4d q_body_to_world_yaw = core::quat_from_euler_zyx(0.0f, 0.0f, yaw);
    const core::Vector4d q_point_to_world = core::quat_mul(q_body_to_world, q_point_to_body);

    // subsampling
    int stride = 1;
    if (total_points > mapMaxPoints) {
      stride = std::max(1, total_points / mapMaxPoints);
    }

    const float max_range2 = mapMaxRangeMeters * mapMaxRangeMeters;
    int used_points = 0;
    int used_points_rerun = 0;

    if (rerun_out) {
      rerun_out->timestamp = lc_data.timestamp;
      rerun_out->points_size = 0;
      rerun_out->colors_size = 0;
      rerun_out->image_size = 0;
      if (kRerunIncludeImage && lc_data.image_size > 0) {
        const size_t copy_size = std::min(lc_data.image_size, rerun_out->image.size());
        std::copy(lc_data.image.begin(), lc_data.image.begin() + copy_size, rerun_out->image.begin());
        rerun_out->image_size = copy_size;
      }
    }
    const core::Vector4d q_point_to_world_yaw = core::quat_mul(q_body_to_world_yaw, q_point_to_body);

    for (int i = 0; i < total_points; ++i) {
      const int base = i * 3;
      float x = lc_data.points[base + 0];
      float y = lc_data.points[base + 1];
      float z = lc_data.points[base + 2];
      if (points_rdf) {
        core::rdf_to_flu(x, y, z, &x, &y, &z);
      }

      const core::Vector3d sensor_point = {x, y, z};
      const core::Vector3d world_point = core::quat_rotate(q_point_to_world, sensor_point);
      const core::Vector3d& wp = world_point;


      // only use points that meet certain criteria in world frame (not too low/high, not too far)
      const float z_world = world_point.z + sensorHeightMeters;
      const bool keep = !(z_world < mapMinZ || z_world > mapMaxZ);
      // Filter in full world frame (roll/pitch/yaw) so range/z checks match true geometry.
      const float r2 = wp.x * wp.x + wp.y * wp.y;
      const bool in_range = (r2 <= max_range2);
      const bool filtered = keep && in_range;

      if (rerun_out && used_points_rerun < sensors::max_points_per_scan) {
        const int out_base = used_points_rerun * 3;

        rerun_out->points[out_base + 0] = wp.x;
        rerun_out->points[out_base + 1] = wp.y;
        rerun_out->points[out_base + 2] = wp.z;

        uint8_t r = 200, g = 200, b = 200;
        const int color_base = i * 3;
        if (lc_data.colors_size >= static_cast<size_t>(color_base + 3)) {
          r = lc_data.colors[color_base + 0];
          g = lc_data.colors[color_base + 1];
          b = lc_data.colors[color_base + 2];
        }
        if (kRerunHighlightFiltered && filtered) {
          r = 255;
          g = 0;
          b = 255;
        }
        if (rerun_out->colors.size() >= static_cast<size_t>(out_base + 3)) {
          rerun_out->colors[out_base + 0] = r;
          rerun_out->colors[out_base + 1] = g;
          rerun_out->colors[out_base + 2] = b;
        }
        used_points_rerun += 1;
      }

      if (update_map && filtered && (i % stride == 0) && used_points < mapMaxPoints) {
        const core::Vector3d map_point = core::quat_rotate(q_point_to_world_yaw, sensor_point);
        set_point(used_points, map_point.x, map_point.y);
        used_points += 1;
      }
    }

    if (rerun_out) {
      rerun_out->points_size = static_cast<size_t>(used_points_rerun * 3);
      rerun_out->colors_size = static_cast<size_t>(used_points_rerun * 3);
    }

    if (!update_map || used_points <= 0) return;

    if (lc_data.timestamp - g_last_map_log_ts < kMapLogIntervalSec) {
      return;
    }
    g_last_map_log_ts = lc_data.timestamp;

    draw_map(1, used_points, mapWidth, mapHeight);

    map_frame.width = get_image_width();
    map_frame.timestamp = lc_data.timestamp;
    map_frame.height = get_image_height();
    map_frame.channels = 4;
    map_frame.data_ptr = static_cast<uint32_t>(
        reinterpret_cast<uintptr_t>(get_image_rgba_ptr()));
    map_frame.data_size = get_image_rgba_size();

    rerun_log_map_frame(&map_frame);

    if (lc_data.timestamp - g_last_yaw_log_ts >= 1.0) {

      g_last_yaw_log_ts = lc_data.timestamp;

      const core::Vector3d a = core::quat_rotate(q_body_to_world, {1.0, 0.0, 0.0});
      const core::Vector3d b = core::quat_rotate(q_body_to_world, {0.0, 1.0, 0.0});
      const core::Vector3d c = core::quat_rotate(q_body_to_world, {0.0, 0.0, 1.0});

      constexpr float deg = 57.29578f;
      const float yaw_x = atan2f(static_cast<float>(a.y), static_cast<float>(a.x)) * deg;
      const float yaw_y = atan2f(static_cast<float>(b.y), static_cast<float>(b.x)) * deg;
      const float yaw_z = atan2f(static_cast<float>(c.y), static_cast<float>(c.x)) * deg;
      std::cout << "Pose yaw deg: " << (yaw * deg)
                << " | yaw_x/y/z=" << yaw_x << "/" << yaw_y << "/" << yaw_z
                << " | fwd=[" << ffw.x << "," << ffw.y << "," << ffw.z << "]"
                << " | range=" << range
                << " | up=[" << c.x << "," << c.y << "," << c.z << "]"
                << std::endl;
    }
  }
}//namespace mapping
