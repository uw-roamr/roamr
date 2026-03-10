#include "mapping/map_update.h"

#include "mapping/map_metadata.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <iostream>
#include <limits>

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
  constexpr int kOccupancyRayBins = 360;
  constexpr int kObstacleEndpointCenterRepeats = 5;
  constexpr double kObstacleEndpointSplatHalfWidthM = 0;


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

  struct RayBinSample {
    bool has_hit = false;
    bool has_free = false;
    double hit_range2 = std::numeric_limits<double>::infinity();
    double free_range2 = std::numeric_limits<double>::infinity();
    double hit_world_x = 0.0;
    double hit_world_y = 0.0;
    double hit_dir_x = 0.0;
    double hit_dir_y = 0.0;
    double free_world_x = 0.0;
    double free_world_y = 0.0;
  };

  inline double elapsed_ms(const std::chrono::steady_clock::time_point& start,
                           const std::chrono::steady_clock::time_point& end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
  }

  inline int ray_bin_from_angle(double angle_rad) {
    const double wrapped = core::normalize_angle(angle_rad);
    const double unit = (wrapped + core::pi) / (2.0 * core::pi);
    int bin = static_cast<int>(std::floor(unit * static_cast<double>(kOccupancyRayBins)));
    if (bin < 0) {
      bin = 0;
    }
    if (bin >= kOccupancyRayBins) {
      bin = kOccupancyRayBins - 1;
    }
    return bin;
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
    std::array<RayBinSample, kOccupancyRayBins> ray_bins{};

    for (int point_idx = 0; point_idx < total_points; ++point_idx) {
      const int i = point_idx * 3;
      const float x = lc_data.points[i + 0];
      const float y = lc_data.points[i + 1];
      const float z = lc_data.points[i + 2];
      core::Vector3d sensor_point = {x, y, z};
      if (points_rdf) {
        sensor_point = core::rdf_to_flu(sensor_point);
      }

      const core::Vector3d body_point = core::quat_rotate(q_point_to_body, sensor_point);
      const double planar_range2 =
          body_point.x * body_point.x + body_point.y * body_point.y;
      const int ray_bin = ray_bin_from_angle(std::atan2(body_point.y, body_point.x));

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

      if (filtered) {
        core::Vector3d map_point = core::quat_rotate(q_point_to_world_yaw, sensor_point);
        map_point.x += t_body_to_world.x;
        map_point.y += t_body_to_world.y;
        RayBinSample& bin = ray_bins[ray_bin];
        if (!bin.has_hit || planar_range2 < bin.hit_range2) {
          bin.has_hit = true;
          bin.hit_range2 = planar_range2;
          bin.hit_world_x = map_point.x;
          bin.hit_world_y = map_point.y;
          const double ray_norm = std::sqrt(std::max(r2, 1e-12));
          bin.hit_dir_x = rdx / ray_norm;
          bin.hit_dir_y = rdy / ray_norm;
        }
      } else if (keep && !in_range && r2 > 1e-9) {
        // Clip the ray to the max-range radius and register it as free-space
        // evidence. No occupancy hit will be recorded at the endpoint.
        const double r = std::sqrt(static_cast<double>(r2));
        const double clip_x = t_body_to_world.x + rdx / r * mapMaxRangeMeters;
        const double clip_y = t_body_to_world.y + rdy / r * mapMaxRangeMeters;
        RayBinSample& bin = ray_bins[ray_bin];
        if (!bin.has_hit && (!bin.has_free || planar_range2 < bin.free_range2)) {
          bin.has_free = true;
          bin.free_range2 = planar_range2;
          bin.free_world_x = clip_x;
          bin.free_world_y = clip_y;
        }
      }
    }

    for (const RayBinSample& bin : ray_bins) {
      if (bin.has_hit && used_points < kMaxMapPoints) {
        for (int repeat = 0; repeat < kObstacleEndpointCenterRepeats; ++repeat) {
          if (used_points >= kMaxMapPoints) {
            break;
          }
          map.set_point(used_points, bin.hit_world_x, bin.hit_world_y);
          ++used_points;
        }

        const double tangent_x = -bin.hit_dir_y;
        const double tangent_y = bin.hit_dir_x;
        const std::array<double, 2> lateral_offsets{
            -kObstacleEndpointSplatHalfWidthM,
            kObstacleEndpointSplatHalfWidthM};
        for (const double lateral_offset : lateral_offsets) {
          if (used_points >= kMaxMapPoints) {
            break;
          }
          map.set_point(
              used_points,
              bin.hit_world_x + tangent_x * lateral_offset,
              bin.hit_world_y + tangent_y * lateral_offset);
          ++used_points;
        }
        continue;
      }
      if (bin.has_free && free_points < kMaxFreeRays) {
        map.set_free_point(free_points, bin.free_world_x, bin.free_world_y);
        ++free_points;
      }
    }


    map.draw_map(map_pose, used_points, free_points);
  }
}//namespace mapping
