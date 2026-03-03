#pragma once

#include <cstdint>

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

void integrate_wheel_odometry(
    const WheelOdometryData& odom,
    double* x,
    double* y,
    double* yaw) {
    if (!x || !y || !yaw) {
        return;
    }
    const double meters_per_tick = (kTwoPi * kWheelRadiusMeters) / kWheelTicksPerRev;
    const double dl = static_cast<double>(odom.dl_ticks) * meters_per_tick;
    const double dr = static_cast<double>(odom.dr_ticks) * meters_per_tick;

    const double ds = 0.5 * (dl + dr);
    const double dtheta = (dr - dl) / kWheelBaseMeters;
    const double heading_mid = *yaw + (0.5 * dtheta);

    *x += ds * std::cos(heading_mid);
    *y += ds * std::sin(heading_mid);
    *yaw += dtheta;
}
} // namespace sensors
