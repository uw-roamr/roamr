#pragma once

#include <array>
#include <cmath>

namespace core {

using Vector3d = std::array<double, 3>;
using Vector4d = std::array<double, 4>;
using Mat3d = std::array<double, 9>;

inline Mat3d mat_eye() noexcept {
  return {1.0, 0.0, 0.0,
          0.0, 1.0, 0.0,
          0.0, 0.0, 1.0};
}

inline Mat3d hat(const Vector3d& v) noexcept {
  return {0.0, -v[2],  v[1],
          v[2],  0.0, -v[0],
         -v[1],  v[0], 0.0};
}

inline void mat_mul(const Mat3d& a, const Mat3d& b, Mat3d& out) noexcept {
  out[0] = a[0]*b[0] + a[1]*b[3] + a[2]*b[6];
  out[1] = a[0]*b[1] + a[1]*b[4] + a[2]*b[7];
  out[2] = a[0]*b[2] + a[1]*b[5] + a[2]*b[8];
  out[3] = a[3]*b[0] + a[4]*b[3] + a[5]*b[6];
  out[4] = a[3]*b[1] + a[4]*b[4] + a[5]*b[7];
  out[5] = a[3]*b[2] + a[4]*b[5] + a[5]*b[8];
  out[6] = a[6]*b[0] + a[7]*b[3] + a[8]*b[6];
  out[7] = a[6]*b[1] + a[7]*b[4] + a[8]*b[7];
  out[8] = a[6]*b[2] + a[7]*b[5] + a[8]*b[8];
}

inline Mat3d mat_mul(const Mat3d& a, const Mat3d& b) noexcept {
  Mat3d out{};
  mat_mul(a, b, out);
  return out;
}

inline double norm(const double x, const double y, const double z) noexcept {
  return std::sqrt(x * x + y * y + z * z);
}

inline double norm(const Vector3d& v) noexcept {
  return std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

}  // namespace core
