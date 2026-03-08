#include "map_update.h"

#include "map_api.h"
#include "visualization.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>

namespace mapping {
  constexpr int mapWidth = 256;
  constexpr int mapHeight = 256;
  constexpr int mapMaxPoints = 20000; // keep in sync with map.cpp
  constexpr int kMapMaxPoses = 4096; // keep in sync with map.cpp
  constexpr float mapMaxRangeMeters = 1.8f;
  constexpr float mapMinZ = 0.1f; // drop ground (world Z up)
  constexpr float mapMaxZ = 0.25f; // drop ceiling/background
  // Sensor height above world origin (meters). Use to convert sensor-relative Z to world Z.
  constexpr float sensorHeightMeters = 0.20f;

  // Rerun logging: include camera image in the filtered lidar frame (expensive copy).
  constexpr bool kRerunIncludeImage = false;
  // Keep rerun point payload bounded to reduce JSON encode + websocket pressure.
  constexpr int kRerunMaxPoints = 4000;
  // Color map-eligible 3D points in rerun for fast filter debugging.
  constexpr bool kRerunHighlightFiltered = true;
  constexpr double kMapLogIntervalSec = 0.1;


  static int g_pose_history_count = 0;
  static double g_last_pose_yaw = 0.0;

  struct MapPerfWindow {
    std::chrono::steady_clock::time_point window_start = std::chrono::steady_clock::now();
    int calls = 0;
    int total_points_sum = 0;
    int used_points_sum = 0;
    double point_loop_ms_sum = 0.0;
    double draw_ms_sum = 0.0;
    double total_ms_sum = 0.0;
  };

  static MapPerfWindow g_map_perf_window;

  inline double elapsed_ms(const std::chrono::steady_clock::time_point& start,
                           const std::chrono::steady_clock::time_point& end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
  }



  void build_rerun_frame_from_lidar(const sensors::LidarCameraData& lc_data,
                                    sensors::LidarCameraData& rerun_out,
                                    const core::PoseSE3d& body_to_world) {
    const int total_points = static_cast<int>(lc_data.points_size / 3);
    rerun_out.timestamp = lc_data.timestamp;
    rerun_out.points_size = 0;
    rerun_out.colors_size = 0;
    rerun_out.image_size = 0;
    rerun_out.points_frame_id = static_cast<core::CoordinateFrameId_t>(core::CoordinateFrameId::kFLU);
    rerun_out.image_frame_id = lc_data.image_frame_id;

    if (kRerunIncludeImage && lc_data.image_size > 0) {
      const size_t copy_size = std::min(lc_data.image_size, rerun_out.image.size());
      std::copy(lc_data.image.begin(), lc_data.image.begin() + copy_size, rerun_out.image.begin());
      rerun_out.image_size = copy_size;
    }

    if (total_points <= 0) {
      return;
    }

    const int max_rerun_points = std::max(1, std::min(kRerunMaxPoints, sensors::max_points_per_scan));
    const int rerun_stride = std::max(1, total_points / max_rerun_points);
    const bool points_rdf =
        lc_data.points_frame_id == static_cast<core::CoordinateFrameId_t>(core::CoordinateFrameId::kRDF);
    const core::Vector4d q_body_to_world = core::quat_normalize(body_to_world.quaternion);
    const core::Vector3d& t_body_to_world = body_to_world.translation;
    const core::Vector4d q_point_to_body = core::quat_from_euler_zyx(core::pi * 0.5, 0.0, 0.0);
    const core::Vector4d q_point_to_world = core::quat_mul(q_body_to_world, q_point_to_body);
    const float max_range2 = mapMaxRangeMeters * mapMaxRangeMeters;

    int used_points_rerun = 0;
    for (int i = 0; i < total_points && used_points_rerun < sensors::max_points_per_scan; i += rerun_stride) {
      const int in_base = i * 3;
      const int out_base = used_points_rerun * 3;

      float x = lc_data.points[in_base + 0];
      float y = lc_data.points[in_base + 1];
      float z = lc_data.points[in_base + 2];
      if (points_rdf) {
        core::rdf_to_flu(x, y, z, &x, &y, &z);
      }

      // Apply camera-to-body mounting correction:
      // (x, y, z) -> (x, -z, y)
      const float corrected_x = x;
      const float corrected_y = -z;
      const float corrected_z = y;

      rerun_out.points[out_base + 0] = corrected_x;
      rerun_out.points[out_base + 1] = corrected_y;
      rerun_out.points[out_base + 2] = corrected_z;

      const core::Vector3d sensor_point = {x, y, z};
      core::Vector3d world_point = core::quat_rotate(q_point_to_world, sensor_point);
      world_point.x += t_body_to_world.x;
      world_point.y += t_body_to_world.y;
      world_point.z += t_body_to_world.z;
      const float z_world = world_point.z + sensorHeightMeters;
      const bool keep = !(z_world < mapMinZ || z_world > mapMaxZ);
      // Range relative to the robot (sensor) position, not the world origin.
      const double rdx = world_point.x - t_body_to_world.x;
      const double rdy = world_point.y - t_body_to_world.y;
      const float r2 = static_cast<float>(rdx * rdx + rdy * rdy);
      const bool in_range = (r2 <= max_range2);
      const bool filtered = keep && in_range;

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
      rerun_out.colors[out_base + 0] = r;
      rerun_out.colors[out_base + 1] = g;
      rerun_out.colors[out_base + 2] = b;
      used_points_rerun += 1;
    }

    rerun_out.points_size = static_cast<size_t>(used_points_rerun * 3);
    rerun_out.colors_size = static_cast<size_t>(used_points_rerun * 3);
  }

  void initialize_map(){
    reset_map();
    reset_points();
    reset_poses();
    set_points_world(1);
    g_pose_history_count = 0;
    g_last_pose_yaw = 0.0;
  }

  void update_map_from_lidar(const sensors::LidarCameraData& lc_data,
                             MapFrame& map_frame,
                             const core::PoseSE3d& body_to_world
                            ) {
    const auto call_start = std::chrono::steady_clock::now();
    const int total_points = static_cast<int>(lc_data.points_size / 3);
    if (total_points <= 0) return;

    // initial transforms
    const core::Vector4d q_body_to_world = core::quat_normalize(body_to_world.quaternion);
    const core::Vector3d& t_body_to_world = body_to_world.translation;
    const bool points_rdf =
        lc_data.points_frame_id == static_cast<core::CoordinateFrameId_t>(core::CoordinateFrameId::kRDF);

    double yaw = core::quat_to_euler_yaw(q_body_to_world);

    if (g_pose_history_count > 0) {
      yaw = core::unwrap_angle_near(yaw, g_last_pose_yaw);
    }
    g_last_pose_yaw = yaw;


    // Correct camera-to-body mounting by +90 deg roll:
    // (x, y, z) -> (x, -z, y)
    // Applying here guarantees map, z filtering, and rerun all use the same corrected geometry.
    const core::Vector4d q_point_to_body = core::quat_from_euler_zyx(core::pi * 0.5, 0.0, 0.0);
    if (g_pose_history_count < kMapMaxPoses) {
      set_pose(g_pose_history_count, t_body_to_world.x, t_body_to_world.y, yaw);
      g_pose_history_count += 1;
    } else {
      set_pose(kMapMaxPoses - 1, t_body_to_world.x, t_body_to_world.y, yaw);
    }

    // for determining yaw of points
    const core::Vector4d q_body_to_world_yaw = core::quat_from_euler_zyx(0.0f, 0.0f, yaw);
    const core::Vector4d q_point_to_world_yaw = core::quat_mul(q_body_to_world_yaw, q_point_to_body);

    const core::Vector4d q_point_to_world = core::quat_mul(q_body_to_world, q_point_to_body);

    // subsampling
    constexpr float max_range2 = mapMaxRangeMeters * mapMaxRangeMeters;
    int used_points = 0;

    for (int i = 0; i < total_points; i += 3) {
      const float x = lc_data.points[i + 0];
      const float y = lc_data.points[i + 1];
      const float z = lc_data.points[i + 2];
      core::Vector3d sensor_point = {x, y, z};
      if (points_rdf) {
        sensor_point = core::rdf_to_flu(sensor_point);
      }

      core::Vector3d world_point = core::quat_rotate(q_point_to_world, sensor_point);
      world_point += t_body_to_world;
      const core::Vector3d& wp = world_point;

      // only use points that meet certain criteria in world frame (not too low/high, not too far)
      const float z_world = world_point.z + sensorHeightMeters;
      const bool keep = !(z_world < mapMinZ || z_world > mapMaxZ);
      // Filter range relative to the robot (sensor) position, not the world origin.
      const double rdx = wp.x - t_body_to_world.x;
      const double rdy = wp.y - t_body_to_world.y;
      const float r2 = static_cast<float>(rdx * rdx + rdy * rdy);
      const bool in_range = (r2 <= max_range2);
      const bool filtered = keep && in_range;

      if (filtered && used_points < mapMaxPoints) {
        core::Vector3d map_point = core::quat_rotate(q_point_to_world_yaw, sensor_point);
        map_point.x += t_body_to_world.x;
        map_point.y += t_body_to_world.y;
        set_point(used_points, map_point.x, map_point.y);
        used_points += 1;
      }
    }

    // Set frame metadata synchronously so update_plan_overlay has valid
    // dimensions immediately. The telemetry thread performs the actual
    // draw_map + rerun_log_map_frame asynchronously after being notified.
    map_frame.timestamp = lc_data.timestamp;
    map_frame.width     = mapWidth;
    map_frame.height    = mapHeight;
    map_frame.channels  = 4;

    visualization::request_render({
        g_pose_history_count, used_points, mapWidth, mapHeight,
        lc_data.timestamp});


  }
}//namespace mapping
