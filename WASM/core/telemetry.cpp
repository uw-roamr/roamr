#include "core/telemetry.h"
#include <algorithm>
#include <math.h>
#include <mutex>
#include <stdint.h>

namespace {
constexpr double kGravityMetersPerSec2 = 9.80665;
constexpr double kImuCalibWindowSec = 1.0;
constexpr double kImuGyroStillThresh = 0.05; // rad/s
constexpr double kImuAccelMagTol = 0.6; // m/s^2
constexpr double kImuAccelStdThresh = 0.15; // m/s^2
constexpr int kImuCalibMinSamples = 30;
constexpr double kLidarLogIntervalSec = 0.1;

// Mapping logic moved to map_update.cpp.

struct ImuCalibration {
  bool calibrated = false;
  double window_start = -1.0;
  int sample_count = 0;
  double sum_acc[3] = {0.0, 0.0, 0.0};
  double sum_acc_sq[3] = {0.0, 0.0, 0.0};
  double sum_gyro[3] = {0.0, 0.0, 0.0};
  double gyro_bias[3] = {0.0, 0.0, 0.0};
  double accel_bias[3] = {0.0, 0.0, 0.0};
  double gravity[3] = {0.0, 0.0, 0.0};
  double timestamp = 0.0;
};

static ImuCalibration g_imu_calib;

void reset_imu_calibration_window(ImuCalibration* calib) {
  calib->window_start = -1.0;
  calib->sample_count = 0;
  calib->sum_acc[0] = calib->sum_acc[1] = calib->sum_acc[2] = 0.0;
  calib->sum_acc_sq[0] = calib->sum_acc_sq[1] = calib->sum_acc_sq[2] = 0.0;
  calib->sum_gyro[0] = calib->sum_gyro[1] = calib->sum_gyro[2] = 0.0;
}

void update_imu_calibration(ImuCalibration* calib, const sensors::IMUData& imu) {
  if (calib->calibrated) {
    return;
  }

  const double ax = imu.acc_x;
  const double ay = imu.acc_y;
  const double az = imu.acc_z;
  const double gx = imu.gyro_x;
  const double gy = imu.gyro_y;
  const double gz = imu.gyro_z;

  const double gyro_norm = sqrt(gx * gx + gy * gy + gz * gz);
  const double acc_norm = sqrt(ax * ax + ay * ay + az * az);
  const bool still = gyro_norm < kImuGyroStillThresh &&
                     fabs(acc_norm - kGravityMetersPerSec2) < kImuAccelMagTol;

  if (!still) {
    reset_imu_calibration_window(calib);
    return;
  }

  if (calib->window_start < 0.0) {
    calib->window_start = imu.timestamp;
  }

  const double elapsed = imu.timestamp - calib->window_start;
  if (elapsed < 0.0 || elapsed > kImuCalibWindowSec * 2.0) {
    reset_imu_calibration_window(calib);
    return;
  }

  calib->sample_count += 1;
  calib->sum_acc[0] += ax;
  calib->sum_acc[1] += ay;
  calib->sum_acc[2] += az;
  calib->sum_acc_sq[0] += ax * ax;
  calib->sum_acc_sq[1] += ay * ay;
  calib->sum_acc_sq[2] += az * az;
  calib->sum_gyro[0] += gx;
  calib->sum_gyro[1] += gy;
  calib->sum_gyro[2] += gz;

  if (elapsed < kImuCalibWindowSec) {
    return;
  }

  if (calib->sample_count < kImuCalibMinSamples) {
    reset_imu_calibration_window(calib);
    return;
  }

  const double n = static_cast<double>(calib->sample_count);
  const double mean_ax = calib->sum_acc[0] / n;
  const double mean_ay = calib->sum_acc[1] / n;
  const double mean_az = calib->sum_acc[2] / n;
  const double mean_gx = calib->sum_gyro[0] / n;
  const double mean_gy = calib->sum_gyro[1] / n;
  const double mean_gz = calib->sum_gyro[2] / n;

  const double var_ax = calib->sum_acc_sq[0] / n - mean_ax * mean_ax;
  const double var_ay = calib->sum_acc_sq[1] / n - mean_ay * mean_ay;
  const double var_az = calib->sum_acc_sq[2] / n - mean_az * mean_az;
  const double accel_std = sqrt(std::max(0.0, (var_ax + var_ay + var_az) / 3.0));
  if (accel_std > kImuAccelStdThresh) {
    reset_imu_calibration_window(calib);
    return;
  }

  const double mean_acc_norm = sqrt(mean_ax * mean_ax + mean_ay * mean_ay + mean_az * mean_az);
  if (mean_acc_norm < 1e-6) {
    reset_imu_calibration_window(calib);
    return;
  }

  const double gx_dir = mean_ax / mean_acc_norm;
  const double gy_dir = mean_ay / mean_acc_norm;
  const double gz_dir = mean_az / mean_acc_norm;

  calib->gyro_bias[0] = mean_gx;
  calib->gyro_bias[1] = mean_gy;
  calib->gyro_bias[2] = mean_gz;
  calib->gravity[0] = gx_dir * kGravityMetersPerSec2;
  calib->gravity[1] = gy_dir * kGravityMetersPerSec2;
  calib->gravity[2] = gz_dir * kGravityMetersPerSec2;
  calib->accel_bias[0] = mean_ax - calib->gravity[0];
  calib->accel_bias[1] = mean_ay - calib->gravity[1];
  calib->accel_bias[2] = mean_az - calib->gravity[2];
  calib->timestamp = imu.timestamp;
  calib->calibrated = true;

  std::cout << "IMU calibrated at t=" << calib->timestamp << "s"
            << " gyro_bias=[" << calib->gyro_bias[0] << "," << calib->gyro_bias[1] << "," << calib->gyro_bias[2] << "]"
            << " gravity=[" << calib->gravity[0] << "," << calib->gravity[1] << "," << calib->gravity[2] << "]"
            << " accel_bias=[" << calib->accel_bias[0] << "," << calib->accel_bias[1] << "," << calib->accel_bias[2] << "]"
            << std::endl;
}


} // namespace

void log_config(const sensors::CameraConfig& cam_config){
  std::cout << "Sensor config" << std::endl;
  std::cout << "T: " << cam_config.timestamp << ", height: " << cam_config.image_height << ", width: " << cam_config.image_width << ", channels: " << cam_config.image_channels << std::endl;
}


void log_imu(std::mutex& m_imu, const sensors::IMUData& imu_data, double& last_imu_timestamp){
  std::cout << std::fixed << std::setprecision(5);

  sensors::IMUData imu_copy;
  {
    std::lock_guard<std::mutex> lk(m_imu);
    imu_copy = imu_data;
  }
  
  if (imu_copy.timestamp <= last_imu_timestamp) {
    std::this_thread::yield();
  }
  last_imu_timestamp = imu_copy.timestamp;
  update_imu_calibration(&g_imu_calib, imu_copy);
  rerun_log_imu(&imu_copy);
  // std::cout << "T:" << imu_copy.timestamp << " acc:" << imu_copy.acc_x << "," << imu_copy.acc_y << "," << imu_copy.acc_z << std::endl
  // << "T:" << imu_copy.timestamp << " gyro:" << imu_copy.gyro_x << "," << imu_copy.gyro_y << "," << imu_copy.gyro_z <<
  // std::endl;
  // std::this_thread::sleep_for(std::chrono::milliseconds(IMUIntervalMs));
}
// log sensors without significant delays in processing
void log_lc(std::mutex& m_lc, const sensors::LidarCameraData& lc_data, double& last_lc_timestamp){
  std::cout << std::fixed << std::setprecision(5);
    
  // very expensive to copy everything!
  {
    std::lock_guard<std::mutex> lk(m_lc);
    const double lc_timestamp = lc_data.timestamp;
    if (lc_timestamp <= last_lc_timestamp){
      std::this_thread::yield();
      return;
    }
    if (lc_timestamp - last_lc_timestamp < kLidarLogIntervalSec) {
      return;
    }
    last_lc_timestamp = lc_timestamp;

  }


};
