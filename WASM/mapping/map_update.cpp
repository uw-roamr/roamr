#include "mapping/map_update.h"

#include "mapping/map_metadata.h"
#include "mapping/visualization.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>

namespace mapping {
  constexpr int mapWidth = 256;
  constexpr int mapHeight = 256;

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

  void initialize_map(Map& map){
    map.reset_map();
    map.reset_points();
    map.reset_poses();
    map.clear_planned_path();
    map.set_points_world(1);
    g_pose_history_count = 0;
    g_last_pose_yaw = 0.0;
  }

  void update_map_from_lidar(Map& map,
                             const sensors::LidarCameraData& lc_data,
                             MapImage& map_frame,
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
    if (g_pose_history_count < kMaxMapPoses) {
      map.set_pose(g_pose_history_count, t_body_to_world.x, t_body_to_world.y, yaw);
      g_pose_history_count += 1;
    } else {
      map.set_pose(kMaxMapPoses - 1, t_body_to_world.x, t_body_to_world.y, yaw);
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

      if (filtered && used_points < kMaxMapPoints) {
        core::Vector3d map_point = core::quat_rotate(q_point_to_world_yaw, sensor_point);
        map_point.x += t_body_to_world.x;
        map_point.y += t_body_to_world.y;
        map.set_point(used_points, map_point.x, map_point.y);
        used_points += 1;
      }
    }

    map.draw_map(g_pose_history_count, used_points);

    visualization::render_map_frame(
        map,
        g_pose_history_count, mapWidth, mapHeight,
        lc_data.timestamp, map_frame);
  }
}//namespace mapping
