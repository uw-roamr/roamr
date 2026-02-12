#include "sensors/imu_preintegration.h"

namespace sensors {

void IMUPreintegrator::integrate(const IMUData& imu) noexcept {
  if (last_ts_ < 0.0) {
    last_ts_ = imu.timestamp;
    return;
  }

  const double dt = imu.timestamp - last_ts_;
  if (dt <= 0.0) {
    return;
  }

  const core::Vector3d w{
      imu.gyro_x - bias_gyro_[0],
      imu.gyro_y - bias_gyro_[1],
      imu.gyro_z - bias_gyro_[2],
  };
  const core::Vector3d a{
      imu.acc_x - bias_acc_[0],
      imu.acc_y - bias_acc_[1],
      imu.acc_z - bias_acc_[2],
  };

  const core::Vector4d dq = core::quat_from_rotvec(w * dt);
  pose_.quaternion = core::quat_normalize(core::quat_mul(pose_.quaternion, dq));

  core::Vector3d a_world = core::quat_rotate(pose_.quaternion, a);
  // If accel already includes gravity, subtract it here.
  a_world -= gravity_;

  const core::Vector3d dp = velocity_ * dt + a_world * (0.5 * dt * dt);
  pose_.translation += dp;
  velocity_ += a_world * dt;

  last_ts_ = imu.timestamp;
}

void IMUPreintegrator::get_pose_log(PoseLog* out) const noexcept {
  if (!out) {
    return;
  }
  out->timestamp = last_ts_;
  out->translation = pose_.translation;
  out->quaternion = pose_.quaternion;
}

}  // namespace sensors
