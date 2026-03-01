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

} // namespace sensors
