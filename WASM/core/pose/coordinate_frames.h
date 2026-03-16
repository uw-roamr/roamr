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

}; //namespace core
