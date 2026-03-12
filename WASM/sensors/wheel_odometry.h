#pragma once

#include <cmath>
#include <cstdint>

#include "core/pose/se2.h"
#include "core/wasm_utils.h"

namespace sensors {

struct WheelOdometryData {
  double timestamp;
  int32_t seq;
  int32_t dl_ticks;
  int32_t dr_ticks;
  int32_t sample_period_ms;
};

WASM_IMPORT("host", "read_wheel_odometry")
void read_wheel_odometry(WheelOdometryData *data);

constexpr double kWheelTicksPerRev = 16384.0; // 2**(14 bit)
constexpr double kWheelRadiusMeters = 0.025;
constexpr double kWheelBaseMeters = 0.155;
constexpr double kTwoPi = 6.28318530717958647692;

struct WheelDeltaMeters {
  double left;
  double right;
};

struct WheelSpeedMetersPerSec {
  double left;
  double right;
  double dt_seconds;
};

constexpr double wheel_meters_per_tick() {
  return (kTwoPi * kWheelRadiusMeters) / kWheelTicksPerRev;
}

inline WheelDeltaMeters wheel_delta_meters_from_ticks(const WheelOdometryData& odom) {
  const double meters_per_tick = wheel_meters_per_tick();
  return WheelDeltaMeters{
      static_cast<double>(odom.dl_ticks) * meters_per_tick,
      static_cast<double>(odom.dr_ticks) * meters_per_tick,
  };
}

inline WheelSpeedMetersPerSec wheel_speed_from_odometry(const WheelOdometryData& odom) {
  const WheelDeltaMeters delta = wheel_delta_meters_from_ticks(odom);
  const double dt_seconds = static_cast<double>(odom.sample_period_ms) * 1e-3;
  if (dt_seconds <= 0.0) {
    return WheelSpeedMetersPerSec{0.0, 0.0, 0.0};
  }
  return WheelSpeedMetersPerSec{
      delta.left / dt_seconds,
      delta.right / dt_seconds,
      dt_seconds,
  };
}

inline void integrate_wheel_odometry(
    const WheelOdometryData& odom,
    core::PoseSE2d& pose) {
  const WheelDeltaMeters delta = wheel_delta_meters_from_ticks(odom);
  const double dl = delta.left;
  const double dr = delta.right;

  const double ds = 0.5 * (dl + dr);
  const double dtheta = (dr - dl) / kWheelBaseMeters;
  const double heading_mid = pose.theta + (0.5 * dtheta);

  pose.x += ds * std::cos(heading_mid);
  pose.y += ds * std::sin(heading_mid);
  pose.theta += dtheta;
}

inline void integrate_wheel_odometry(
    const WheelOdometryData& odom,
    double heading,
    core::PoseSE2d& pose) {
  const WheelDeltaMeters delta = wheel_delta_meters_from_ticks(odom);
  const double ds = 0.5 * (delta.left + delta.right);

  // In FLU, positive wheel travel should move the body forward along +x.
  pose.x += ds * std::cos(heading);
  pose.y += ds * std::sin(heading);
  pose.theta = heading;
}
} // namespace sensors
