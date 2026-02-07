#include "telemetry.h"
#include "lidar_camera.h"
#include "map_api.h"
#include <algorithm>
#include <math.h>
#include <mutex>
#include <stdint.h>

namespace {
constexpr int mapWidth = 256;
constexpr int mapHeight = 256;
constexpr int mapMaxPoints = 20000; // keep in sync with map.cpp
constexpr double mapMinInterval = 0.2; // seconds
constexpr float mapMaxRangeMeters = 1.8f; //
constexpr float mapMinZ = 0.0f; // drop ground (world Z up)
constexpr float mapMaxZ = 0.15f; // drop ceiling/background
// Sensor height above world origin (meters). Use to convert sensor-relative Z to world Z.
constexpr float sensorHeightMeters = 0.20f;
// Mounting offset between device FLU and robot/body FLU.
// Adjust these (radians) if the phone is mounted rotated relative to robot forward.
constexpr float mountRoll = 0.0f;
constexpr float mountPitch = 0.0f;
constexpr float mountYaw = 0.0f;
// Point cloud frame correction (camera FLU -> device FLU).
// For portrait, back-camera-forward mounting, yaw showing up as pitch indicates
// the camera frame is rolled +90 deg relative to device. Compensate here.
constexpr float pointRoll = -0.5f * static_cast<float>(M_PI);
constexpr float pointPitch = 0.0f;
constexpr float pointYaw = 0.0f;
// Rerun logging: include camera image in the filtered lidar frame (expensive copy).
constexpr bool kRerunIncludeImage = false;
// Rerun logging: highlight filtered points in bright pink.
constexpr bool kRerunHighlightFiltered = true;
// Rerun logging: use full roll/pitch/yaw rotation for point positions (recommended for 3D view).
constexpr bool kRerunUseFullRotation = true;

static bool g_map_initialized = false;
static double g_last_map_timestamp = -1.0;
static MapFrame g_map_frame;
static LidarCameraData g_rerun_lc;

struct Quatf {
  float x, y, z, w;
};

static bool g_imu_calibrated = false;
// Initial ref->body orientation used to define world frame.
static Quatf g_ref_to_body0 = {0.0f, 0.0f, 0.0f, 1.0f};
static double g_last_yaw_log_ts = -1.0;

void rotate_with_quat(const Quatf& q, float vx, float vy, float vz, float* ox, float* oy, float* oz);

Quatf quat_normalize(Quatf q) {
  const float n = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
  if (n < 1e-6f) return {0.0f, 0.0f, 0.0f, 1.0f};
  const float inv = 1.0f / sqrtf(n);
  q.x *= inv;
  q.y *= inv;
  q.z *= inv;
  q.w *= inv;
  return q;
}

Quatf quat_conj(Quatf q) {
  return {-q.x, -q.y, -q.z, q.w};
}

Quatf quat_mul(Quatf a, Quatf b) {
  return {
      a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
      a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
      a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
      a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  };
}

Quatf quat_from_euler(float roll, float pitch, float yaw) {
  const float cr = cosf(roll * 0.5f);
  const float sr = sinf(roll * 0.5f);
  const float cp = cosf(pitch * 0.5f);
  const float sp = sinf(pitch * 0.5f);
  const float cy = cosf(yaw * 0.5f);
  const float sy = sinf(yaw * 0.5f);

  Quatf q{
      sr * cp * cy - cr * sp * sy,
      cr * sp * cy + sr * cp * sy,
      cr * cp * sy - sr * sp * cy,
      cr * cp * cy + sr * sp * sy,
  };
  return quat_normalize(q);
}

Quatf mount_quat() {
  static const Quatf q = quat_from_euler(mountRoll, mountPitch, mountYaw);
  return q;
}

Quatf imu_ref_to_device(const IMUData& imu_data) {
  const Quatf q{
      static_cast<float>(imu_data.quat_x),
      static_cast<float>(imu_data.quat_y),
      static_cast<float>(imu_data.quat_z),
      static_cast<float>(imu_data.quat_w),
  };
  return quat_normalize(q);
}

Quatf imu_body_to_world(const IMUData& imu_data) {
  if (imu_data.att_timestamp <= 0.0) {
    return {0.0f, 0.0f, 0.0f, 1.0f};
  }
  const Quatf q_ref_to_device = imu_ref_to_device(imu_data);
  const Quatf q_mount = mount_quat();
  const Quatf q_ref_to_body = quat_mul(q_mount, q_ref_to_device);
  if (!g_imu_calibrated) {
    g_ref_to_body0 = q_ref_to_body;
    std::cout << "IMU calibration: world frame locked to initial pose" << std::endl;
    g_imu_calibrated = true;
  }
  // body->world = body->ref * ref->body0
  return quat_mul(quat_conj(q_ref_to_body), g_ref_to_body0);
}

void rotate_with_quat(const Quatf& q, float vx, float vy, float vz, float* ox, float* oy, float* oz) {
  // v' = v + 2*cross(q_vec, cross(q_vec, v) + w*v)
  const float qx = q.x;
  const float qy = q.y;
  const float qz = q.z;
  const float qw = q.w;

  const float tx = 2.0f * (qy * vz - qz * vy);
  const float ty = 2.0f * (qz * vx - qx * vz);
  const float tz = 2.0f * (qx * vy - qy * vx);

  *ox = vx + qw * tx + (qy * tz - qz * ty);
  *oy = vy + qw * ty + (qz * tx - qx * tz);
  *oz = vz + qw * tz + (qx * ty - qy * tx);
}

void update_map_from_lidar(const LidarCameraData& lc_data, const IMUData& imu_data, LidarCameraData* rerun_out, bool update_map) {
  const int total_points = static_cast<int>(lc_data.points_size / 3);
  if (total_points <= 0) return;

  if (update_map && !g_map_initialized) {
    reset_map();
    reset_points();
    reset_poses();
    set_points_world(1);
    set_pose(0, 0.0f, 0.0f, 0.0f);
    g_map_initialized = true;
  }

  const Quatf q_body_to_world = imu_body_to_world(imu_data);
  float ax = 1.0f, ay = 0.0f, az = 0.0f;
  float bx = 0.0f, by = 1.0f, bz = 0.0f;
  float cx = 0.0f, cy = 0.0f, cz = 1.0f;
  rotate_with_quat(q_body_to_world, 1.0f, 0.0f, 0.0f, &ax, &ay, &az);
  rotate_with_quat(q_body_to_world, 0.0f, 1.0f, 0.0f, &bx, &by, &bz);
  rotate_with_quat(q_body_to_world, 0.0f, 0.0f, 1.0f, &cx, &cy, &cz);

  const float fwx = ax;
  const float fwy = ay;
  const float yaw = atan2f(fwy, fwx);
  const float horiz = sqrtf(fwx * fwx + fwy * fwy);
  const Quatf q_body_to_world_yaw = quat_from_euler(0.0f, 0.0f, yaw);
  const Quatf q_mount = mount_quat();
  const Quatf q_point_to_device = quat_from_euler(pointRoll, pointPitch, pointYaw);
  const Quatf q_point_to_body = quat_mul(q_mount, q_point_to_device);
  const Quatf q_point_to_world = quat_mul(q_body_to_world, q_point_to_body);
  const Quatf q_point_to_world_yaw = quat_mul(q_body_to_world_yaw, q_point_to_body);
  set_pose(0, 0.0f, 0.0f, yaw);
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

  for (int i = 0; i < total_points; i += 1) {
    const int base = i * 3;
    const float x = lc_data.points[base + 0];
    const float y = lc_data.points[base + 1];
    const float z = lc_data.points[base + 2];

    float wx = 0.0f, wy = 0.0f, wz = 0.0f;
    rotate_with_quat(q_point_to_world_yaw, x, y, z, &wx, &wy, &wz);
    float wx_full = 0.0f, wy_full = 0.0f, wz_full = 0.0f;
    rotate_with_quat(q_point_to_world, x, y, z, &wx_full, &wy_full, &wz_full);

    const float wz_world = wz_full + sensorHeightMeters;
    const bool keep = !(wz_world < mapMinZ || wz_world > mapMaxZ);
    // Filter in full world frame (roll/pitch/yaw) so range/z checks match true geometry.
    const float r2 = wx_full * wx_full + wy_full * wy_full;
    const bool in_range = (r2 <= max_range2);
    const bool filtered = keep && in_range;

    if (rerun_out && used_points_rerun < max_points_per_scan) {
      const int out_base = used_points_rerun * 3;
      const float rx = kRerunUseFullRotation ? wx_full : wx;
      const float ry = kRerunUseFullRotation ? wy_full : wy;
      const float rz = wz_full;
      rerun_out->points[out_base + 0] = rx;
      rerun_out->points[out_base + 1] = ry;
      rerun_out->points[out_base + 2] = rz;

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
      set_point(used_points, wx, wy);
      used_points += 1;
    }
  }

  if (rerun_out) {
    rerun_out->points_size = static_cast<size_t>(used_points_rerun * 3);
    rerun_out->colors_size = static_cast<size_t>(used_points_rerun * 3);
  }

  if (!update_map || used_points <= 0) return;

  draw_map(1, used_points, mapWidth, mapHeight);

  g_map_frame.timestamp = lc_data.timestamp;
  g_map_frame.width = get_image_width();
  g_map_frame.height = get_image_height();
  g_map_frame.channels = 4;
  g_map_frame.data_ptr = static_cast<uint32_t>(
      reinterpret_cast<uintptr_t>(get_image_rgba_ptr()));
  g_map_frame.data_size = get_image_rgba_size();

  rerun_log_map_frame(&g_map_frame);

  if (lc_data.timestamp - g_last_yaw_log_ts >= 1.0) {
    g_last_yaw_log_ts = lc_data.timestamp;
    const float deg = 57.29578f;
    const float yaw_x = atan2f(ay, ax) * deg;
    const float yaw_y = atan2f(by, bx) * deg;
    const float yaw_z = atan2f(cy, cx) * deg;
    std::cout << "IMU yaw deg: " << (yaw * deg)
              << " | yaw_x/y/z=" << yaw_x << "/" << yaw_y << "/" << yaw_z
              << " | fwd=[" << ax << "," << ay << "," << az << "]"
              << " | horiz=" << horiz
              << " | up=[" << cx << "," << cy << "," << cz << "]"
              << std::endl;
  }
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
          const bool do_map_update = (lc_timestamp - g_last_map_timestamp >= mapMinInterval);
          if (do_map_update) {
            g_last_map_timestamp = lc_timestamp;
          }
          update_map_from_lidar(lc_data, imu_copy, &g_rerun_lc, do_map_update);
          if (g_rerun_lc.points_size > 0) {
            rerun_log_lidar_frame(&g_rerun_lc);
          }
        }
      }
    }

        // std::cout << "T:" << imu_copy.acc_timestamp << " acc:" << imu_copy.acc_x << "," << imu_copy.acc_y << "," << imu_copy.acc_z << std::endl
        //             << "T:" << imu_copy.gyro_timestamp << " gyro:" << imu_copy.gyro_x << "," << imu_copy.gyro_y << "," << imu_copy.gyro_z <<
        //             std::endl;
        // if (has_new_lc) {
          // std::cout << "T:" << lc_timestamp << " points size: " << points_size << ", image size: " << image_size << std::endl;
        // }
  }
};
