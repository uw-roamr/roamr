#pragma once

#include <array>

#include "core/pose/se3.h"
#include "sensors/calibration.h"
#include "sensors/imu.h"

namespace sensors {

struct PoseLog {
  double timestamp;
  core::Vector3d translation;
  core::Vector4d quaternion;
};

class IMUPreintegrator {
 public:
  explicit IMUPreintegrator(calibration::IMUCalibration& imu_calib) noexcept
      : imu_calib_(imu_calib) {
    reset();
  }

  void reset() noexcept {
    pose_ = core::PoseSE3d();
    velocity_ = {};
    gyro_yaw_ = 0.0;
    last_ts_ = -1.0;
  }

  void update_bias() noexcept {
    bias_gyro_[0] = imu_calib_.gyro_bias[0];
    bias_gyro_[1] = imu_calib_.gyro_bias[1];
    bias_gyro_[2] = imu_calib_.gyro_bias[2];
    bias_acc_[0] = imu_calib_.acc_bias[0];
    bias_acc_[1] = imu_calib_.acc_bias[1];
    bias_acc_[2] = imu_calib_.acc_bias[2];
    gravity_[0] = imu_calib_.gravity[0];
    gravity_[1] = imu_calib_.gravity[1];
    gravity_[2] = imu_calib_.gravity[2];
  }

  void integrate(const IMUData& imu) noexcept;
  void get_pose_log(PoseLog* out) const noexcept;

  const core::PoseSE3d& pose() const noexcept { return pose_; }
  double gyro_yaw() const noexcept { return gyro_yaw_; }

 private:
  calibration::IMUCalibration& imu_calib_;
  core::PoseSE3d pose_;
  core::Vector3d velocity_;
  core::Vector3d bias_gyro_;
  core::Vector3d bias_acc_;
  core::Vector3d gravity_;
  double gyro_yaw_ = 0.0;
  double last_ts_ = -1.0;
};

}  // namespace sensors
