#include "telemetry.h"
#include "lidar_camera.h"
#include "map_api.h"
#include <algorithm>
#include <mutex>
#include <stdint.h>

namespace {
constexpr int kMapWidth = 256;
constexpr int kMapHeight = 256;
constexpr int kMapMaxPoints = 20000; // keep in sync with map.cpp
constexpr double kMapMinInterval = 0.2; // seconds
constexpr float kMapMaxRangeMeters = 1.8f; //
constexpr float kMapMinZ = 0.0f; // drop ground (FLU: Z up)
constexpr float kMapMaxZ = 0.05f; // drop ceiling/background

static bool g_map_initialized = false;
static double g_last_map_timestamp = -1.0;
static MapFrame g_map_frame;

void update_map_from_lidar(const LidarCameraData& lc_data) {
  const int total_points = static_cast<int>(lc_data.points_size / 3);
  if (total_points <= 0) return;

  if (!g_map_initialized) {
    reset_map();
    reset_points();
    reset_poses();
    set_points_world(0);
    set_pose(0, 0.0f, 0.0f, 0.0f);
    g_map_initialized = true;
  }

  int stride = 1;
  if (total_points > kMapMaxPoints) {
    stride = std::max(1, total_points / kMapMaxPoints);
  }

  const float max_range2 = kMapMaxRangeMeters * kMapMaxRangeMeters;
  int used_points = 0;
  for (int i = 0; i < total_points && used_points < kMapMaxPoints; i += stride) {
    const int base = i * 3;
    const float x = lc_data.points[base + 0];
    const float y = lc_data.points[base + 1];
    const float z = lc_data.points[base + 2];
    if (z < kMapMinZ || z > kMapMaxZ) continue;
    const float r2 = x * x + y * y;
    if (r2 > max_range2) continue;
    set_point(used_points, x, y);
    used_points += 1;
  }

  if (used_points <= 0) return;

  draw_map(1, used_points, kMapWidth, kMapHeight);

  g_map_frame.timestamp = lc_data.timestamp;
  g_map_frame.width = get_image_width();
  g_map_frame.height = get_image_height();
  g_map_frame.channels = 4;
  g_map_frame.data_ptr = static_cast<uint32_t>(
      reinterpret_cast<uintptr_t>(get_image_rgba_ptr()));
  g_map_frame.data_size = get_image_rgba_size();

  rerun_log_map_frame(&g_map_frame);
}
} // namespace

void log_config(const CameraConfig& cam_config){
  std::cout << "Sensor config" << std::endl;
  std::cout << "T: " << cam_config.timestamp << ", height: " << cam_config.image_height << ", width: " << cam_config.image_width << ", channels: " << cam_config.image_channels << std::endl;
}

// log sensors without significant delays in processing
void log_sensors(std::mutex& m_imu, const IMUData& imu_data, std::mutex& m_lc, const LidarCameraData& lc_data){
  std::cout << std::fixed << std::setprecision(5);
  double last_lc_timestamp = -1.0;
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(log_interval_ms));

    IMUData imu_copy;
    {
      std::lock_guard<std::mutex> lk(m_imu);
      imu_copy = imu_data;
    }

    // very expensive to copy everything!
    double lc_timestamp;
    size_t image_size, points_size;
    bool has_new_lc = false;
    
    {
      std::lock_guard<std::mutex> lk(m_lc);
      lc_timestamp = lc_data.timestamp;
      points_size = lc_data.points_size;
      image_size = lc_data.image_size; 
      if (lc_timestamp != last_lc_timestamp) {
        last_lc_timestamp = lc_timestamp;
        has_new_lc = true;
        if (points_size > 0) {
          rerun_log_lidar_frame(&lc_data);
          if (lc_timestamp - g_last_map_timestamp >= kMapMinInterval) {
            g_last_map_timestamp = lc_timestamp;
            update_map_from_lidar(lc_data);
          }
        }
      }
    }

        // std::cout << "T:" << imu_copy.acc_timestamp << " acc:" << imu_copy.acc_x << "," << imu_copy.acc_y << "," << imu_copy.acc_z << std::endl
        //             << "T:" << imu_copy.gyro_timestamp << " gyro:" << imu_copy.gyro_x << "," << imu_copy.gyro_y << "," << imu_copy.gyro_z <<
        //             std::endl;
        if (has_new_lc) {
          std::cout << "T:" << lc_timestamp << " points size: " << points_size << ", image size: " << image_size << std::endl;
        }
  }
};
