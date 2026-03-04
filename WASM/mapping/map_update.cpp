#include "map_update.h"

#include "map_api.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>

namespace mapping {
  constexpr int mapWidth = 256;
  constexpr int mapHeight = 256;
  constexpr int mapMaxPoints = 20000; // keep in sync with map.cpp
  constexpr int mapMaxPoses = 4096; // keep in sync with map.cpp
  constexpr float mapMaxRangeMeters = 1.8f;
  constexpr float mapMinZ = 0.1f; // drop ground (world Z up)
  constexpr float mapMaxZ = 0.25f; // drop ceiling/background
  // Sensor height above world origin (meters). Use to convert sensor-relative Z to world Z.
  constexpr float sensorHeightMeters = 0.20f;

  // Rerun logging: include camera image in the filtered lidar frame (expensive copy).
  constexpr bool kRerunIncludeImage = false;
  // Keep rerun point payload bounded to reduce JSON encode + websocket pressure.
  constexpr int kRerunMaxPoints = 4000;
  constexpr double kMapLogIntervalSec = 0.1;
  constexpr double kPerfLogIntervalSec = 2.0;
  constexpr bool kLogYawDebug = false;


  static double g_last_yaw_log_ts = -1.0;
  static double g_last_map_log_ts = -1.0;
  static int g_pose_history_count = 0;

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

  void observe_map_perf(int total_points,
                        int used_points,
                        double point_loop_ms,
                        double draw_ms,
                        double total_ms) {
    g_map_perf_window.calls += 1;
    g_map_perf_window.total_points_sum += total_points;
    g_map_perf_window.used_points_sum += used_points;
    g_map_perf_window.point_loop_ms_sum += point_loop_ms;
    g_map_perf_window.draw_ms_sum += draw_ms;
    g_map_perf_window.total_ms_sum += total_ms;

    const auto now = std::chrono::steady_clock::now();
    const double elapsed_sec =
        std::chrono::duration<double>(now - g_map_perf_window.window_start).count();
    if (elapsed_sec < kPerfLogIntervalSec) {
      return;
    }

    const int calls = std::max(1, g_map_perf_window.calls);
    const double call_rate_hz = static_cast<double>(g_map_perf_window.calls) / std::max(1e-6, elapsed_sec);
    const double avg_total_points = static_cast<double>(g_map_perf_window.total_points_sum) / calls;
    const double avg_used_points = static_cast<double>(g_map_perf_window.used_points_sum) / calls;
    const double avg_point_loop_ms = g_map_perf_window.point_loop_ms_sum / calls;
    const double avg_draw_ms = g_map_perf_window.draw_ms_sum / calls;
    const double avg_total_ms = g_map_perf_window.total_ms_sum / calls;

    std::cout << "[mapping][map_update] "
              << "rate=" << call_rate_hz << "/s"
              << " total_pts=" << avg_total_points
              << " used_pts=" << avg_used_points
              << " point_loop_ms=" << avg_point_loop_ms
              << " draw_ms=" << avg_draw_ms
              << " total_ms=" << avg_total_ms
              << std::endl;

    g_map_perf_window.window_start = now;
    g_map_perf_window.calls = 0;
    g_map_perf_window.total_points_sum = 0;
    g_map_perf_window.used_points_sum = 0;
    g_map_perf_window.point_loop_ms_sum = 0.0;
    g_map_perf_window.draw_ms_sum = 0.0;
    g_map_perf_window.total_ms_sum = 0.0;
  }


  void build_rerun_frame_from_lidar(const sensors::LidarCameraData& lc_data,
                                    sensors::LidarCameraData& rerun_out) {
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

      uint8_t r = 200, g = 200, b = 200;
      const int color_base = i * 3;
      if (lc_data.colors_size >= static_cast<size_t>(color_base + 3)) {
        r = lc_data.colors[color_base + 0];
        g = lc_data.colors[color_base + 1];
        b = lc_data.colors[color_base + 2];
      }
      rerun_out.colors[out_base + 0] = r;
      rerun_out.colors[out_base + 1] = g;
      rerun_out.colors[out_base + 2] = b;
      used_points_rerun += 1;
    }

    rerun_out.points_size = static_cast<size_t>(used_points_rerun * 3);
    rerun_out.colors_size = static_cast<size_t>(used_points_rerun * 3);
  }

  void update_map_from_lidar(const sensors::LidarCameraData& lc_data,
                             MapFrame& map_frame,
                             bool& map_initialized,
                             const core::Vector4d& q_body_to_world_in,
                             const core::Vector3d& t_body_to_world_in
                            //  const core::PoseSE3d& pose,
                            //  const bool rotation_only_bc_imu_drifts
                            ) {
    const auto call_start = std::chrono::steady_clock::now();
    const int total_points = static_cast<int>(lc_data.points_size / 3);
    if (total_points <= 0) return;

    if (!map_initialized) {
      reset_map();
      reset_points();
      reset_poses();
      set_points_world(1);
      g_pose_history_count = 0;
      map_initialized = true;
    }

    const core::Vector4d q_body_to_world = core::quat_normalize(q_body_to_world_in);
    const core::Vector3d t_body_to_world = t_body_to_world_in;
    const bool points_rdf =
        lc_data.points_frame_id == static_cast<core::CoordinateFrameId_t>(core::CoordinateFrameId::kRDF);

    // Use the phone-facing axis (camera forward) as +X for mapping.
    const core::Vector3d forward_flu = {1.0, 0.0, 0.0};

    // Correct camera-to-body mounting by +90 deg roll:
    // (x, y, z) -> (x, -z, y)
    // Applying here guarantees map, z filtering, and rerun all use the same corrected geometry.
    const core::Vector4d q_point_to_body = core::quat_from_euler_zyx(core::pi * 0.5, 0.0, 0.0);
    const core::Vector3d forward_flu_body = core::quat_rotate(q_point_to_body, forward_flu);

    const core::Vector3d forward_flu_world = core::quat_rotate(q_body_to_world, forward_flu_body);
    const core::Vector3d& ffw = forward_flu_world;

    // project to SE2
    const double yaw = std::atan2(ffw.y, ffw.x);
    const double range = std::sqrt(ffw.x * ffw.x + ffw.y * ffw.y);
    if (g_pose_history_count < mapMaxPoses) {
      set_pose(g_pose_history_count, t_body_to_world.x, t_body_to_world.y, yaw);
      g_pose_history_count += 1;
    } else {
      set_pose(mapMaxPoses - 1, t_body_to_world.x, t_body_to_world.y, yaw);
    }


    const core::Vector4d q_body_to_world_yaw = core::quat_from_euler_zyx(0.0f, 0.0f, yaw);
    const core::Vector4d q_point_to_world = core::quat_mul(q_body_to_world, q_point_to_body);

    // subsampling
    int stride = 1;
    if (total_points > mapMaxPoints) {
      stride = std::max(1, total_points / mapMaxPoints);
    }
    const float max_range2 = mapMaxRangeMeters * mapMaxRangeMeters;
    int used_points = 0;
    const core::Vector4d q_point_to_world_yaw = core::quat_mul(q_body_to_world_yaw, q_point_to_body);

    const auto point_loop_start = std::chrono::steady_clock::now();
    for (int i = 0; i < total_points; ++i) {
      const int base = i * 3;
      float x = lc_data.points[base + 0];
      float y = lc_data.points[base + 1];
      float z = lc_data.points[base + 2];
      if (points_rdf) {
        core::rdf_to_flu(x, y, z, &x, &y, &z);
      }

      const core::Vector3d sensor_point = {x, y, z};
      core::Vector3d world_point = core::quat_rotate(q_point_to_world, sensor_point);
      world_point.x += t_body_to_world.x;
      world_point.y += t_body_to_world.y;
      world_point.z += t_body_to_world.z;
      const core::Vector3d& wp = world_point;


      // only use points that meet certain criteria in world frame (not too low/high, not too far)
      const float z_world = world_point.z + sensorHeightMeters;
      const bool keep = !(z_world < mapMinZ || z_world > mapMaxZ);
      // Filter in full world frame (roll/pitch/yaw) so range/z checks match true geometry.
      const float r2 = wp.x * wp.x + wp.y * wp.y;
      const bool in_range = (r2 <= max_range2);
      const bool filtered = keep && in_range;

      if (filtered && (i % stride == 0) && used_points < mapMaxPoints) {
        core::Vector3d map_point = core::quat_rotate(q_point_to_world_yaw, sensor_point);
        map_point.x += t_body_to_world.x;
        map_point.y += t_body_to_world.y;
        set_point(used_points, map_point.x, map_point.y);
        used_points += 1;
      }
    }
    const auto point_loop_end = std::chrono::steady_clock::now();
    const double point_loop_ms = elapsed_ms(point_loop_start, point_loop_end);

    if (lc_data.timestamp - g_last_map_log_ts < kMapLogIntervalSec) {
      const auto call_end = std::chrono::steady_clock::now();
      observe_map_perf(
          total_points,
          used_points,
          point_loop_ms,
          0.0,
          elapsed_ms(call_start, call_end));
      return;
    }
    g_last_map_log_ts = lc_data.timestamp;

    const auto draw_start = std::chrono::steady_clock::now();
    draw_map(g_pose_history_count, used_points, mapWidth, mapHeight);
    const auto draw_end = std::chrono::steady_clock::now();
    const double draw_ms = elapsed_ms(draw_start, draw_end);

    map_frame.width = get_image_width();
    map_frame.timestamp = lc_data.timestamp;
    map_frame.height = get_image_height();
    map_frame.channels = 4;
    map_frame.data_ptr = static_cast<uint32_t>(
        reinterpret_cast<uintptr_t>(get_image_rgba_ptr()));
    map_frame.data_size = get_image_rgba_size();

    rerun_log_map_frame(&map_frame);

    const auto call_end = std::chrono::steady_clock::now();
    observe_map_perf(
        total_points,
        used_points,
        point_loop_ms,
        draw_ms,
        elapsed_ms(call_start, call_end));

    if (kLogYawDebug && lc_data.timestamp - g_last_yaw_log_ts >= 1.0) {

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
