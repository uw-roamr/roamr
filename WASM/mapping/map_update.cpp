#include "mapping/map_update.h"

#include "mapping/map_metadata.h"

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
    map.reset_free_points();
    map.set_points_world(1);
  }

  bool build_map_snapshot(const Map& map,
                          const core::PoseSE3d& body_to_world,
                          double timestamp,
                          uint64_t map_revision,
                          MapSnapshot* out_snapshot) {
    if (!out_snapshot) {
      return false;
    }

    OccupancyGridMetadata meta{};
    if (!map.get_occupancy_meta(&meta)) {
      return false;
    }

    MapSnapshot snapshot;
    snapshot.meta = meta;
    snapshot.timestamp = timestamp;
    snapshot.map_revision = map_revision;
    snapshot.pose = core::PoseSE2d{
        body_to_world.translation.x,
        body_to_world.translation.y,
        core::quat_to_euler_yaw(core::quat_normalize(body_to_world.quaternion))};
    snapshot.occupancy.assign(
        static_cast<size_t>(meta.width * meta.height),
        static_cast<int8_t>(-1));
    const int32_t copied = map.get_occupancy_grid(
        snapshot.occupancy.data(),
        static_cast<int32_t>(snapshot.occupancy.size()));
    if (copied != meta.width * meta.height) {
      return false;
    }

    *out_snapshot = std::move(snapshot);
    return true;
  }

  void update_map_from_lidar(Map& map,
                             const sensors::LidarCameraData& lc_data,
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
    const core::PoseSE2d map_pose{
        t_body_to_world.x,
        t_body_to_world.y,
        yaw};

    // Correct camera-to-body mounting by +90 deg roll:
    // (x, y, z) -> (x, -z, y)
    // Applying here guarantees map, z filtering, and rerun all use the same corrected geometry.
    const core::Vector4d q_point_to_body = core::quat_from_euler_zyx(core::pi * 0.5, 0.0, 0.0);

    // for determining yaw of points
    const core::Vector4d q_body_to_world_yaw = core::quat_from_euler_zyx(0.0f, 0.0f, yaw);
    const core::Vector4d q_point_to_world_yaw = core::quat_mul(q_body_to_world_yaw, q_point_to_body);

    const core::Vector4d q_point_to_world = core::quat_mul(q_body_to_world, q_point_to_body);

    // subsampling
    constexpr float max_range2 = mapMaxRangeMeters * mapMaxRangeMeters;
    int used_points = 0;
    int free_points = 0;

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
      const double r2 = rdx * rdx + rdy * rdy;
      const bool in_range = (r2 <= max_range2);
      const bool filtered = keep && in_range;

      if (filtered && used_points < kMaxMapPoints) {
        core::Vector3d map_point = core::quat_rotate(q_point_to_world_yaw, sensor_point);
        map_point.x += t_body_to_world.x;
        map_point.y += t_body_to_world.y;
        map.set_point(used_points, map_point.x, map_point.y);
        used_points += 1;
      } else if (keep && !in_range && free_points < kMaxFreeRays) {
        // Clip the ray to the max-range radius and register it as free-space
        // evidence. No occupancy hit will be recorded at the endpoint.
        const double r = std::sqrt(static_cast<double>(r2));
        const double clip_x = t_body_to_world.x + rdx / r * mapMaxRangeMeters;
        const double clip_y = t_body_to_world.y + rdy / r * mapMaxRangeMeters;
        map.set_free_point(free_points, clip_x, clip_y);
        free_points += 1;
      }
    }


    map.draw_map(map_pose, used_points, free_points);
  }
}//namespace mapping
