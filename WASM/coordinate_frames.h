#pragma once
#include <stdint.h>

using FrameId = int32_t;

enum class CoordinateFrameId : int32_t {
  kRDF = 0, // right-down-forward (common for cameras)
  kFLU = 1, // default (base_link, IMU, etc.)
};
