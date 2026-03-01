#pragma once
#include <stdint.h>
#include <array>
#include <cmath>

#include "core/math_utils.h"

namespace core{
  using CoordinateFrameId_t = int32_t;

  enum class CoordinateFrameId : int32_t {
    kRDF = 0, // right-down-forward (common for cameras)
    kFLU = 1, // default (base_link, IMU, etc.)
  };

  constexpr double kSmallTheta = 1e-6;
  static void exp_SO3d(const Vector3d& v, Mat3d& mat){
    mat = mat_eye();
    const double theta = norm(v);
    const Mat3d K = hat(v);
    if (theta < kSmallTheta) {
      for (size_t i = 0; i < mat.size(); ++i) {
        mat[i] += K[i];
      }
      return;
    }
    Mat3d K2{};
    mat_mul(K, K, K2);
    const double a = std::sin(theta) / theta;
    const double b = (1.0 - std::cos(theta)) / (theta * theta);
    for (size_t i = 0; i < mat.size(); ++i) {
      mat[i] += a * K[i] + b * K2[i];
    }
  }
  struct PoseSE3d{
    Vector3d translation;
    Vector4d quaternion;
    CoordinateFrameId_t frame_id;

    PoseSE3d(){
      translation = {};
      quaternion = quat_identity();
      frame_id = static_cast<CoordinateFrameId_t>(CoordinateFrameId::kFLU);
    }
  };

  template <typename T>
  inline void rdf_to_flu(T x, T y, T z, T* ox, T* oy, T* oz) noexcept {
    // RDF (x=right, y=down, z=forward) -> FLU (x=forward, y=left, z=up)
    *ox = z;
    *oy = -x;
    *oz = -y;
  }

  inline Vector3d rdf_to_flu(const Vector3d& v) noexcept {
    return {v.z, -v.x, -v.y};
  }
}; //namespace core
