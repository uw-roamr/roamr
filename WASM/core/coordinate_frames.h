#pragma once
#include <stdint.h>

namespace core{
  using CoordinateFrameId_t = int32_t;

  enum class CoordinateFrameId : int32_t {
    kRDF = 0, // right-down-forward (common for cameras)
    kFLU = 1, // default (base_link, IMU, etc.)
  };
}; //namespace core