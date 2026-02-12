#pragma once
#include <stdint.h>
#include <array>
namespace core{
  using CoordinateFrameId_t = int32_t;

  enum class CoordinateFrameId : int32_t {
    kRDF = 0, // right-down-forward (common for cameras)
    kFLU = 1, // default (base_link, IMU, etc.)
  };

  using Vector3d = std::array<double, 3>;
  using Vector4d = std::array<double, 4>;


  struct PoseSE3d{
    Vector3d translation;
    Vector4d quaternion;
    CoordinateFrameId_t frame_id;

    PoseSE3d(){
      translation.fill(0.0);
      quaternion.fill(0.0);
      frame_id = static_cast<CoordinateFrameId_t>(CoordinateFrameId::kFLU);
    }
  };
}; //namespace core
