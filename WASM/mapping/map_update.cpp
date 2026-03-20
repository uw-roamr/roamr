#include "mapping/map_update.h"

#include "mapping/map_metadata.h"
#include "sensors/calibration.h"

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
  constexpr float mapMinZ = 0.05f; // drop ground (world Z up)
  constexpr float mapMaxZ = 0.22f; // tuned upper cutoff: lower noise without the 0.25 drift tradeoff
  // Sensor height above world origin (meters). Use to convert sensor-relative Z to world Z.
  constexpr float sensorHeightMeters = 0.20f;

  // logging: include camera image in the filtered lidar frame (expensive copy).
  constexpr bool kLogIncludeImage = false;
  // Keep rerun point payload bounded to reduce JSON encode + websocket pressure.
  constexpr int kLogMaxPoints = 4000;
  // Color map-eligible 3D points in rerun for fast filter debugging.
  constexpr bool kLogHighlightFiltered = true;
  constexpr double kMapLogIntervalSec = 0.1;
  constexpr int kHitRayBins = 1024;
  constexpr int kFreeRayBins = 512;
  constexpr int kMaxRawPointsPerScan = 12000;
  constexpr int kMapPreprocessSlices = 1;


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

  struct HitDirectionalBinSample {
    bool has_hit = false;
    double hit_range2 = std::numeric_limits<double>::infinity();
    double hit_world_x = 0.0;
    double hit_world_y = 0.0;
  };

  struct FreeDirectionalBinSample {
    bool has_free = false;
    double free_range2 = std::numeric_limits<double>::infinity();
    double free_world_x = 0.0;
    double free_world_y = 0.0;
  };

  inline double elapsed_ms(const std::chrono::steady_clock::time_point& start,
                           const std::chrono::steady_clock::time_point& end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
  }

  inline int ray_bin_from_angle(double angle_rad, int bin_count) {
    const double wrapped = core::normalize_angle(angle_rad);
    const double unit = (wrapped + core::pi) / (2.0 * core::pi);
    int bin = static_cast<int>(std::floor(unit * static_cast<double>(bin_count)));
    if (bin < 0) {
      bin = 0;
    }
    if (bin >= bin_count) {
      bin = bin_count - 1;
    }
    return bin;
  }

  template <typename Sample, size_t N>
  inline void reset_directional_bins(
      std::array<Sample, N>* bins) {
    if (!bins) {
      return;
    }
    for (Sample& bin : *bins) {
      bin = Sample{};
    }
  }

  inline void merge_hit_directional_bins(
      const std::array<HitDirectionalBinSample, kHitRayBins>& src,
      std::array<HitDirectionalBinSample, kHitRayBins>* dst) {
    if (!dst) {
      return;
    }
    for (int i = 0; i < kHitRayBins; ++i) {
      const HitDirectionalBinSample& src_bin = src[i];
      HitDirectionalBinSample& dst_bin = (*dst)[i];
      if (src_bin.has_hit &&
          (!dst_bin.has_hit || src_bin.hit_range2 < dst_bin.hit_range2)) {
        dst_bin.has_hit = true;
        dst_bin.hit_range2 = src_bin.hit_range2;
        dst_bin.hit_world_x = src_bin.hit_world_x;
        dst_bin.hit_world_y = src_bin.hit_world_y;
      }
    }
  }

  inline void merge_free_directional_bins(
      const std::array<FreeDirectionalBinSample, kFreeRayBins>& src,
      std::array<FreeDirectionalBinSample, kFreeRayBins>* dst) {
    if (!dst) {
      return;
    }
    for (int i = 0; i < kFreeRayBins; ++i) {
      const FreeDirectionalBinSample& src_bin = src[i];
      FreeDirectionalBinSample& dst_bin = (*dst)[i];
      if (src_bin.has_free &&
          (!dst_bin.has_free || src_bin.free_range2 < dst_bin.free_range2)) {
        dst_bin.has_free = true;
        dst_bin.free_range2 = src_bin.free_range2;
        dst_bin.free_world_x = src_bin.free_world_x;
        dst_bin.free_world_y = src_bin.free_world_y;
      }
    }
  }

  inline bool free_bin_overlaps_hit(
      int free_bin,
      const std::array<HitDirectionalBinSample, kHitRayBins>& hit_bins) {
    const int hit_begin = (free_bin * kHitRayBins) / kFreeRayBins;
    const int hit_end = ((free_bin + 1) * kHitRayBins + kFreeRayBins - 1) / kFreeRayBins;
    for (int hit_bin = hit_begin; hit_bin < std::min(hit_end, kHitRayBins); ++hit_bin) {
      if (hit_bins[hit_bin].has_hit) {
        return true;
      }
    }
    return false;
  }

  void classify_lidar_points_into_directional_bins(
      const sensors::LidarCameraData& lc_data,
      int point_begin,
      int point_end,
      int point_stride,
      const core::Vector3d& t_lidar_to_world,
      double r00,
      double r01,
      double r02,
      double r10,
      double r11,
      double r12,
      double r20,
      double r21,
      double r22,
      std::array<HitDirectionalBinSample, kHitRayBins>* hit_bins,
      std::array<FreeDirectionalBinSample, kFreeRayBins>* free_bins) {
    if (!hit_bins || !free_bins) {
      return;
    }
    for (int point_idx = point_begin; point_idx < point_end; point_idx += point_stride) {
      const int i = point_idx * 3;
      const double lidar_x = lc_data.points[i + 0];
      const double lidar_y = -lc_data.points[i + 2];
      const double lidar_z = lc_data.points[i + 1];
      const double rel_x = r00 * lidar_x + r01 * lidar_y + r02 * lidar_z;
      const double rel_y = r10 * lidar_x + r11 * lidar_y + r12 * lidar_z;
      const double world_z =
          r20 * lidar_x + r21 * lidar_y + r22 * lidar_z + t_lidar_to_world.z;
      const double z_world = world_z + sensorHeightMeters;
      if (z_world < mapMinZ || z_world > mapMaxZ) {
        continue;
      }

      const double planar_range2 = lidar_x * lidar_x + lidar_y * lidar_y;
      const double r2 = rel_x * rel_x + rel_y * rel_y;
      if (r2 <= static_cast<double>(mapMaxRangeMeters * mapMaxRangeMeters)) {
        const int hit_bin = ray_bin_from_angle(std::atan2(lidar_y, lidar_x), kHitRayBins);
        HitDirectionalBinSample& bin = (*hit_bins)[hit_bin];
        if (!bin.has_hit || planar_range2 < bin.hit_range2) {
          bin.has_hit = true;
          bin.hit_range2 = planar_range2;
          bin.hit_world_x = rel_x + t_lidar_to_world.x;
          bin.hit_world_y = rel_y + t_lidar_to_world.y;
        }
        continue;
      }

      if (r2 <= 1e-9) {
        continue;
      }

      const double r = std::sqrt(r2);
      const int free_bin = ray_bin_from_angle(std::atan2(lidar_y, lidar_x), kFreeRayBins);
      FreeDirectionalBinSample& bin = (*free_bins)[free_bin];
      if (!bin.has_free || planar_range2 < bin.free_range2) {
        bin.has_free = true;
        bin.free_range2 = planar_range2;
        bin.free_world_x = t_lidar_to_world.x + rel_x / r * mapMaxRangeMeters;
        bin.free_world_y = t_lidar_to_world.y + rel_y / r * mapMaxRangeMeters;
      }
    }
  }

  void initialize_map(Map& map){
    map.reset_map();
    map.reset_points();
    map.reset_free_points();
    map.set_points_world(1);
  }

  bool build_map_snapshot(const Map& map,
                          const core::PoseSE3d& world_T_base_link,
                          double timestamp,
                          uint64_t map_revision,
                          MapSnapshot* out_snapshot,
                          double* out_occupancy_copy_seconds) {
    if (!out_snapshot) {
      return false;
    }
    if (out_occupancy_copy_seconds) {
      *out_occupancy_copy_seconds = 0.0;
    }

    OccupancyGridMetadata meta{};
    if (!map.get_occupancy_meta(&meta)) {
      return false;
    }

    out_snapshot->meta = meta;
    out_snapshot->timestamp = timestamp;
    out_snapshot->map_revision = map_revision;
    out_snapshot->pose = core::PoseSE2d{
        world_T_base_link.translation.x,
        world_T_base_link.translation.y,
        core::quat_to_euler_yaw(core::quat_normalize(world_T_base_link.quaternion))};
    const size_t occupancy_size =
        static_cast<size_t>(meta.width * meta.height);
    if (out_snapshot->occupancy.size() != occupancy_size) {
      out_snapshot->occupancy.resize(occupancy_size, static_cast<int8_t>(-1));
    }
    const auto occupancy_copy_started_at = std::chrono::steady_clock::now();
    const int32_t copied = map.get_occupancy_grid(
        out_snapshot->occupancy.data(),
        static_cast<int32_t>(out_snapshot->occupancy.size()));
    if (out_occupancy_copy_seconds) {
      *out_occupancy_copy_seconds =
          std::chrono::duration<double>(
              std::chrono::steady_clock::now() - occupancy_copy_started_at)
              .count();
    }
    if (copied != meta.width * meta.height) {
      return false;
    }
    return true;
  }

  void update_map_from_lidar(Map& map,
                             const sensors::LidarCameraData& lc_data,
                             const core::PoseSE3d& world_T_base_link,
                             std::vector<planning::GridCoord>* out_newly_occupied_cells,
                             MapUpdatePerf* out_perf
                            ) {
    const int total_points = static_cast<int>(lc_data.points_size / 3);
    if (out_perf) {
      *out_perf = MapUpdatePerf{};
    }
    if (total_points <= 0) return;
    if (out_newly_occupied_cells) {
      out_newly_occupied_cells->clear();
    }
    static thread_local std::vector<uint32_t> s_newly_occupied_mask;
    static thread_local uint32_t s_newly_occupied_stamp = 1;
    const size_t grid_cells = static_cast<size_t>(Map::kMapSizeX * Map::kMapSizeY);
    if (out_newly_occupied_cells && s_newly_occupied_mask.size() != grid_cells) {
      s_newly_occupied_mask.assign(grid_cells, 0);
      s_newly_occupied_stamp = 1;
    } else if (out_newly_occupied_cells) {
      ++s_newly_occupied_stamp;
      if (s_newly_occupied_stamp == 0) {
        std::fill(
            s_newly_occupied_mask.begin(),
            s_newly_occupied_mask.end(),
            static_cast<uint32_t>(0));
        s_newly_occupied_stamp = 1;
      }
    }

    const core::PoseSE3d world_T_lidar =
        world_T_base_link * sensors::calibration::base_link_T_lidar;
    const core::Vector4d quat_world_T_lidar = core::quat_normalize(world_T_lidar.quaternion);
    const core::Vector3d& t_lidar_to_world = world_T_lidar.translation;
    const double qx = quat_world_T_lidar.x;
    const double qy = quat_world_T_lidar.y;
    const double qz = quat_world_T_lidar.z;
    const double qw = quat_world_T_lidar.w;
    const double xx = qx * qx;
    const double yy = qy * qy;
    const double zz = qz * qz;
    const double xy = qx * qy;
    const double xz = qx * qz;
    const double yz = qy * qz;
    const double wx = qw * qx;
    const double wy = qw * qy;
    const double wz = qw * qz;
    const double r00 = 1.0 - 2.0 * (yy + zz);
    const double r01 = 2.0 * (xy - wz);
    const double r02 = 2.0 * (xz + wy);
    const double r10 = 2.0 * (xy + wz);
    const double r11 = 1.0 - 2.0 * (xx + zz);
    const double r12 = 2.0 * (yz - wx);
    const double r20 = 2.0 * (xz - wy);
    const double r21 = 2.0 * (yz + wx);
    const double r22 = 1.0 - 2.0 * (xx + yy);
    const double yaw = core::quat_to_euler_yaw(quat_world_T_lidar);
    const core::PoseSE2d map_pose{
        t_lidar_to_world.x,
        t_lidar_to_world.y,
        yaw};

    constexpr float max_range2 = mapMaxRangeMeters * mapMaxRangeMeters;
    int used_points = 0;
    int free_points = 0;
    std::array<HitDirectionalBinSample, kHitRayBins> hit_ray_bins{};
    std::array<FreeDirectionalBinSample, kFreeRayBins> free_ray_bins{};
    reset_directional_bins(&hit_ray_bins);
    reset_directional_bins(&free_ray_bins);
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

    const int point_stride =
        std::max(1, (total_points + kMaxRawPointsPerScan - 1) / kMaxRawPointsPerScan);

    const auto classify_started_at = std::chrono::steady_clock::now();
    if constexpr (kMapPreprocessSlices == 1) {
      classify_lidar_points_into_directional_bins(
          lc_data,
          0,
          total_points,
          point_stride,
          t_lidar_to_world,
          r00,
          r01,
          r02,
          r10,
          r11,
          r12,
          r20,
          r21,
          r22,
          &hit_ray_bins,
          &free_ray_bins);
    } else {
      std::array<std::array<HitDirectionalBinSample, kHitRayBins>, kMapPreprocessSlices>
          slice_hit_bins{};
      std::array<std::array<FreeDirectionalBinSample, kFreeRayBins>, kMapPreprocessSlices>
          slice_free_bins{};
      const int slice_span =
          (total_points + kMapPreprocessSlices - 1) / kMapPreprocessSlices;
      for (int slice_idx = 0; slice_idx < kMapPreprocessSlices; ++slice_idx) {
        reset_directional_bins(&slice_hit_bins[slice_idx]);
        reset_directional_bins(&slice_free_bins[slice_idx]);
        const int point_begin = slice_idx * slice_span;
        const int point_end = std::min(total_points, point_begin + slice_span);
        if (point_begin >= point_end) {
          continue;
        }
        classify_lidar_points_into_directional_bins(
            lc_data,
            point_begin,
            point_end,
            point_stride,
            t_lidar_to_world,
            r00,
            r01,
            r02,
            r10,
            r11,
            r12,
            r20,
            r21,
            r22,
            &slice_hit_bins[slice_idx],
            &slice_free_bins[slice_idx]);
      }
      for (int slice_idx = 0; slice_idx < kMapPreprocessSlices; ++slice_idx) {
        merge_hit_directional_bins(slice_hit_bins[slice_idx], &hit_ray_bins);
        merge_free_directional_bins(slice_free_bins[slice_idx], &free_ray_bins);
      }
    }
    const double classify_seconds =
        std::chrono::duration<double>(
            std::chrono::steady_clock::now() - classify_started_at)
            .count();

    const auto hit_integrate_started_at = std::chrono::steady_clock::now();
    for (const HitDirectionalBinSample& bin : hit_ray_bins) {
      if (!bin.has_hit || used_points >= kMaxMapPoints || !ensure_scan_ready()) {
        continue;
      }
      map.integrate_hit_world(
          start_x,
          start_y,
          map_pose,
          bin.hit_world_x,
          bin.hit_world_y,
          out_newly_occupied_cells,
          out_newly_occupied_cells ? &s_newly_occupied_mask : nullptr,
          s_newly_occupied_stamp);
      ++used_points;
    }
    const double hit_integrate_seconds =
        std::chrono::duration<double>(
            std::chrono::steady_clock::now() - hit_integrate_started_at)
            .count();

    const auto free_integrate_started_at = std::chrono::steady_clock::now();
    for (int free_bin = 0; free_bin < kFreeRayBins; ++free_bin) {
      const FreeDirectionalBinSample& bin = free_ray_bins[free_bin];
      if (free_bin_overlaps_hit(free_bin, hit_ray_bins)) {
        continue;
      }
      if (bin.has_free && free_points < kMaxFreeRays && ensure_scan_ready()) {
        map.integrate_free_world(
            start_x,
            start_y,
            bin.free_world_x,
            bin.free_world_y);
        ++free_points;
      }
    }
    const double free_integrate_seconds =
        std::chrono::duration<double>(
            std::chrono::steady_clock::now() - free_integrate_started_at)
            .count();
    if (out_perf) {
      out_perf->classify_seconds = classify_seconds;
      out_perf->hit_integrate_seconds = hit_integrate_seconds;
      out_perf->free_integrate_seconds = free_integrate_seconds;
      out_perf->selected_hit_bins = static_cast<size_t>(used_points);
      out_perf->selected_free_bins = static_cast<size_t>(free_points);
    }
  }
}//namespace mapping
