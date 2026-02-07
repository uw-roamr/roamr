#include "telemetry.h"
#include "lidar_camera.h"
#include "map_api.h"
#include <algorithm>
#include <math.h>
#include <mutex>
#include <stdint.h>

namespace {
constexpr int kMapWidth = 256;
constexpr int kMapHeight = 256;
constexpr int kMapMaxPoints = 20000; // keep in sync with map.cpp
constexpr double kMapMinInterval = 0.2; // seconds
// constexpr float kMapMaxRangeMeters = 1.8f; //
constexpr float kMapMaxRangeMeters = 5.0f; //
// constexpr float kMapMinZ = 0.0f; // drop ground (world Z up)
constexpr float kMapMinZ = -5.0f; // drop ground (world Z up)
constexpr float kMapMaxZ = 5.0f; // drop ceiling/background
// Mounting offset between device FLU and robot/body FLU.
// Adjust these (radians) if the phone is mounted rotated relative to robot forward.
constexpr float kMountRoll = 0.0f;
constexpr float kMountPitch = 0.0f;
constexpr float kMountYaw = 0.0f;
// Point cloud frame correction (camera FLU -> device/robot FLU).
// Points are already in FLU (cameraRdfToFlu + portrait depth rotation), so keep zero unless pipeline changes.
constexpr float kPointRoll = 0.0f;
constexpr float kPointPitch = 0.0f;
constexpr float kPointYaw = 0.0f;

static bool g_map_initialized = false;
static double g_last_map_timestamp = -1.0;
static MapFrame g_map_frame;

struct Quatf {
  float x, y, z, w;
};

static bool g_imu_calibrated = false;
static Quatf g_ref_to_robot0 = {0.0f, 0.0f, 0.0f, 1.0f};
static float g_last_yaw = 0.0f;
static double g_last_yaw_log_ts = -1.0;
static double g_last_gyro_ts = -1.0;

void rotate_with_quat(const Quatf& q, float vx, float vy, float vz, float* ox, float* oy, float* oz);

float wrap_pi(float a) {
  const float two_pi = 2.0f * static_cast<float>(M_PI);
  while (a > static_cast<float>(M_PI)) a -= two_pi;
  while (a < -static_cast<float>(M_PI)) a += two_pi;
  return a;
}

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
  const Quatf q_mount = quat_from_euler(kMountRoll, kMountPitch, kMountYaw);
  const Quatf q_ref_to_robot = quat_mul(q_mount, q_ref_to_device);
  if (!g_imu_calibrated) {
    g_ref_to_robot0 = q_ref_to_robot;
    std::cout << "IMU calibration: heading zeroed" << std::endl;
    g_imu_calibrated = true;
  }
  const Quatf q_ref_to_robot_cal = quat_mul(quat_conj(g_ref_to_robot0), q_ref_to_robot);
  return quat_conj(q_ref_to_robot_cal);
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

void update_map_from_lidar(const LidarCameraData& lc_data, const IMUData& imu_data) {
  const int total_points = static_cast<int>(lc_data.points_size / 3);
  if (total_points <= 0) return;

  if (!g_map_initialized) {
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
  const float yaw_meas = atan2f(fwy, fwx);
  float yaw = g_last_yaw;
  const float horiz = sqrtf(fwx * fwx + fwy * fwy);

  // Integrate gyro about FLU Z as a fallback when forward is near vertical.
  if (imu_data.gyro_timestamp > 0.0) {
    if (g_last_gyro_ts < 0.0) {
      g_last_gyro_ts = imu_data.gyro_timestamp;
    } else {
      const double dt = imu_data.gyro_timestamp - g_last_gyro_ts;
      g_last_gyro_ts = imu_data.gyro_timestamp;
      if (dt > 0.0 && dt < 0.2) {
        yaw += static_cast<float>(imu_data.gyro_z) * static_cast<float>(dt);
      }
    }
  }

  // When the forward axis is reliable, correct the gyro-integrated yaw.
  if (horiz > 0.3f) {
    const float delta = wrap_pi(yaw_meas - yaw);
    const float alpha = 0.2f; // blend factor toward measurement
    yaw = yaw + alpha * delta;
  }

  g_last_yaw = yaw;
  const Quatf q_body_to_world_yaw = quat_from_euler(0.0f, 0.0f, yaw);
  const Quatf q_cam_to_body = quat_from_euler(kPointRoll, kPointPitch, kPointYaw);
  set_pose(0, 0.0f, 0.0f, yaw);
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

    float bx = 0.0f, by = 0.0f, bz = 0.0f;
    rotate_with_quat(q_cam_to_body, x, y, z, &bx, &by, &bz);
    float wx = 0.0f, wy = 0.0f, wz = 0.0f;
    rotate_with_quat(q_body_to_world_yaw, bx, by, bz, &wx, &wy, &wz);
    float wx_full = 0.0f, wy_full = 0.0f, wz_full = 0.0f;
    rotate_with_quat(q_body_to_world, bx, by, bz, &wx_full, &wy_full, &wz_full);

    if (wz_full < kMapMinZ || wz_full > kMapMaxZ) continue;
    const float r2 = wx * wx + wy * wy;
    if (r2 > max_range2) continue;
    set_point(used_points, wx, wy);
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

  if (lc_data.timestamp - g_last_yaw_log_ts >= 1.0) {
    g_last_yaw_log_ts = lc_data.timestamp;
    const float deg = 57.29578f;
    const float yaw_x = atan2f(ay, ax) * deg;
    const float yaw_y = atan2f(by, bx) * deg;
    const float yaw_z = atan2f(cy, cx) * deg;
    std::cout << "IMU yaw deg: " << (yaw * deg)
              << " (meas " << (yaw_meas * deg) << ")"
              << " | yaw_x/y/z=" << yaw_x << "/" << yaw_y << "/" << yaw_z
              << " | fwd=[" << ax << "," << ay << "," << az << "]"
              << " | horiz=" << horiz
              << " | up=[" << cx << "," << cy << "," << cz << "]"
              << " | gyro_z:" << static_cast<float>(imu_data.gyro_z)
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
          rerun_log_lidar_frame(&lc_data);
          if (lc_timestamp - g_last_map_timestamp >= kMapMinInterval) {
            g_last_map_timestamp = lc_timestamp;
            update_map_from_lidar(lc_data, imu_copy);
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
