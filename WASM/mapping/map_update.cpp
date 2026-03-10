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
  constexpr int kOccupancyRayBins = 1024;


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
    bool has_free = false;
    double free_range2 = std::numeric_limits<double>::infinity();
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

    out_snapshot->meta = meta;
    out_snapshot->timestamp = timestamp;
    out_snapshot->map_revision = map_revision;
    out_snapshot->pose = core::PoseSE2d{
        body_to_world.translation.x,
        body_to_world.translation.y,
        core::quat_to_euler_yaw(core::quat_normalize(body_to_world.quaternion))};
    const size_t occupancy_size =
        static_cast<size_t>(meta.width * meta.height);
    if (out_snapshot->occupancy.size() != occupancy_size) {
      out_snapshot->occupancy.resize(occupancy_size, static_cast<int8_t>(-1));
    }
    const int32_t copied = map.get_occupancy_grid(
        out_snapshot->occupancy.data(),
        static_cast<int32_t>(out_snapshot->occupancy.size()));
    if (copied != meta.width * meta.height) {
      return false;
    }
    return true;
  }

  void update_map_from_lidar(Map& map,
                             const sensors::LidarCameraData& lc_data,
                             const core::PoseSE3d& body_to_world,
                             std::vector<planning::GridCoord>* out_changed_cells,
                             std::vector<planning::GridCoord>* out_newly_occupied_cells
                            ) {
    const int total_points = static_cast<int>(lc_data.points_size / 3);
    if (total_points <= 0) return;
    if (out_changed_cells) {
      out_changed_cells->clear();
    }
    if (out_newly_occupied_cells) {
      out_newly_occupied_cells->clear();
    }
    static thread_local std::vector<uint8_t> s_changed_mask;
    static thread_local std::vector<uint8_t> s_newly_occupied_mask;
    const size_t grid_cells = static_cast<size_t>(Map::kMapSizeX * Map::kMapSizeY);
    if (out_changed_cells) {
      s_changed_mask.assign(grid_cells, 0);
    }
    if (out_newly_occupied_cells) {
      s_newly_occupied_mask.assign(grid_cells, 0);
    }

    const core::Vector4d q_body_to_world = core::quat_normalize(body_to_world.quaternion);
    const core::Vector3d& t_body_to_world = body_to_world.translation;
    const double yaw = core::quat_to_euler_yaw(q_body_to_world);
    const core::PoseSE2d map_pose{
        t_body_to_world.x,
        t_body_to_world.y,
        yaw};
    const double cos_yaw = std::cos(yaw);
    const double sin_yaw = std::sin(yaw);

    constexpr float max_range2 = mapMaxRangeMeters * mapMaxRangeMeters;
    int used_points = 0;
    int free_points = 0;
    std::array<RayBinSample, kOccupancyRayBins> ray_bins{};
    int32_t start_x = 0;
    int32_t start_y = 0;
    bool scan_ready = false;

    auto ensure_scan_ready = [&]() {
      if (scan_ready) {
        return true;
      }
      scan_ready = map.begin_scan_integration(map_pose, &start_x, &start_y);
      return scan_ready;
    };

    for (int point_idx = 0; point_idx < total_points; ++point_idx) {
      const int i = point_idx * 3;
      // LiDAR points are already FLU here, but they still need the fixed
      // camera-to-body mounting correction: (x, y, z) -> (x, -z, y).
      const core::Vector3d body_point{
          lc_data.points[i + 0],
          -lc_data.points[i + 2],
          lc_data.points[i + 1]};
      const double planar_range2 =
          body_point.x * body_point.x + body_point.y * body_point.y;
      const int ray_bin = ray_bin_from_angle(std::atan2(body_point.y, body_point.x));

      core::Vector3d world_point = core::quat_rotate(q_body_to_world, body_point);
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
        if (used_points < kMaxMapPoints && ensure_scan_ready()) {
          const core::Vector3d map_point{
              t_body_to_world.x + cos_yaw * body_point.x - sin_yaw * body_point.y,
              t_body_to_world.y + sin_yaw * body_point.x + cos_yaw * body_point.y,
              0.0};
          map.integrate_hit_world(
              start_x,
              start_y,
              map_pose,
              map_point.x,
              map_point.y,
              out_changed_cells,
              out_changed_cells ? &s_changed_mask : nullptr,
              out_newly_occupied_cells,
              out_newly_occupied_cells ? &s_newly_occupied_mask : nullptr);
          ++used_points;
        }
      } else if (keep && !in_range && r2 > 1e-9) {
        // Clip the ray to the max-range radius and register it as free-space
        // evidence. No occupancy hit will be recorded at the endpoint.
        const double r = std::sqrt(static_cast<double>(r2));
        const double clip_x = t_body_to_world.x + rdx / r * mapMaxRangeMeters;
        const double clip_y = t_body_to_world.y + rdy / r * mapMaxRangeMeters;
        RayBinSample& bin = ray_bins[ray_bin];
        if (!bin.has_free || planar_range2 < bin.free_range2) {
          bin.has_free = true;
          bin.free_range2 = planar_range2;
          bin.free_world_x = clip_x;
          bin.free_world_y = clip_y;
        }
      }
    }

    for (const RayBinSample& bin : ray_bins) {
      if (bin.has_free && free_points < kMaxFreeRays && ensure_scan_ready()) {
        map.integrate_free_world(
            start_x,
            start_y,
            bin.free_world_x,
            bin.free_world_y,
            out_changed_cells,
            out_changed_cells ? &s_changed_mask : nullptr);
        ++free_points;
      }
    }
  }
}//namespace mapping
