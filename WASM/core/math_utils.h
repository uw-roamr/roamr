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

inline double dot(const Vector3d& a, const Vector3d& b) noexcept {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

inline Vector3d cross(const Vector3d& a, const Vector3d& b) noexcept {
  return {
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0],
  };
}

inline Vector3d vec_add(const Vector3d& a, const Vector3d& b) noexcept {
  return {a[0] + b[0], a[1] + b[1], a[2] + b[2]};
}

inline Vector3d vec_sub(const Vector3d& a, const Vector3d& b) noexcept {
  return {a[0] - b[0], a[1] - b[1], a[2] - b[2]};
}

inline Vector3d vec_scale(const Vector3d& v, double s) noexcept {
  return {v[0] * s, v[1] * s, v[2] * s};
}

inline void vec_iadd(Vector3d& a, const Vector3d& b) noexcept {
  a[0] += b[0];
  a[1] += b[1];
  a[2] += b[2];
}

inline void vec_isub(Vector3d& a, const Vector3d& b) noexcept {
  a[0] -= b[0];
  a[1] -= b[1];
  a[2] -= b[2];
}

inline Vector4d quat_identity() noexcept {
  return {0.0, 0.0, 0.0, 1.0};
}

inline Vector4d quat_conj(const Vector4d& q) noexcept {
  return {-q[0], -q[1], -q[2], q[3]};
}

inline Vector4d quat_mul(const Vector4d& a, const Vector4d& b) noexcept {
  const Vector3d av{a[0], a[1], a[2]};
  const Vector3d bv{b[0], b[1], b[2]};
  const Vector3d cv = vec_add(vec_add(vec_scale(bv, a[3]), vec_scale(av, b[3])), cross(av, bv));
  const double w = a[3] * b[3] - dot(av, bv);
  return {cv[0], cv[1], cv[2], w};
}

inline Vector4d quat_normalize(const Vector4d& q) noexcept {
  const double n = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  if (n < 1e-12) {
    return quat_identity();
  }
  return {q[0] / n, q[1] / n, q[2] / n, q[3] / n};
}

inline Vector4d quat_from_rotvec(const Vector3d& w) noexcept {
  const double theta = norm(w);
  if (theta < 1e-6) {
    return {0.5 * w[0], 0.5 * w[1], 0.5 * w[2], 1.0};
  }
  const double half = 0.5 * theta;
  const double s = std::sin(half) / theta;
  return {w[0] * s, w[1] * s, w[2] * s, std::cos(half)};
}

inline Vector3d quat_rotate(const Vector4d& q, const Vector3d& v) noexcept {
  const Vector3d qv{q[0], q[1], q[2]};
  const Vector3d t = vec_scale(cross(qv, v), 2.0);
  return vec_add(v, vec_add(vec_scale(t, q[3]), cross(qv, t)));
}

}  // namespace core
