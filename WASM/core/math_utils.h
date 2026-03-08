#pragma once

#include <array>
#include <cmath>
#include <cstddef>

namespace core {

constexpr double pi = 3.141592653589793238462643383279502884;

struct Vector3d {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;

  constexpr Vector3d() = default;
  constexpr Vector3d(double x_, double y_, double z_) : x(x_), y(y_), z(z_) {}

  double& operator[](size_t i) { return (&x)[i]; }
  const double& operator[](size_t i) const { return (&x)[i]; }

  Vector3d& operator+=(const Vector3d& other) {
    x += other.x;
    y += other.y;
    z += other.z;
    return *this;
  }
  Vector3d& operator-=(const Vector3d& other) {
    x -= other.x;
    y -= other.y;
    z -= other.z;
    return *this;
  }
  Vector3d& operator*=(double s) {
    x *= s;
    y *= s;
    z *= s;
    return *this;
  }
};

inline Vector3d operator+(Vector3d a, const Vector3d& b) { return a += b; }
inline Vector3d operator-(Vector3d a, const Vector3d& b) { return a -= b; }
inline Vector3d operator*(Vector3d a, double s) { return a *= s; }
inline Vector3d operator*(double s, Vector3d a) { return a *= s; }

struct Vector4d {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;
  double w = 0.0;

  constexpr Vector4d() = default;
  constexpr Vector4d(double x_, double y_, double z_, double w_)
      : x(x_), y(y_), z(z_), w(w_) {}

  double& operator[](size_t i) { return (&x)[i]; }
  const double& operator[](size_t i) const { return (&x)[i]; }
};
using Mat3d = std::array<double, 9>;

inline Mat3d mat_eye() noexcept {
  return {1.0, 0.0, 0.0,
          0.0, 1.0, 0.0,
          0.0, 0.0, 1.0};
}

inline Mat3d hat(const Vector3d& v) noexcept {
  return {0.0, -v.z,  v.y,
          v.z,  0.0, -v.x,
         -v.y,  v.x, 0.0};
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
  return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

inline double dot(const Vector3d& a, const Vector3d& b) noexcept {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline Vector3d cross(const Vector3d& a, const Vector3d& b) noexcept {
  return {
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x,
  };
}

inline Vector3d vec_add(const Vector3d& a, const Vector3d& b) noexcept {
  return a + b;
}

inline Vector3d vec_sub(const Vector3d& a, const Vector3d& b) noexcept {
  return a - b;
}

inline Vector3d vec_scale(const Vector3d& v, double s) noexcept {
  return v * s;
}

inline void vec_iadd(Vector3d& a, const Vector3d& b) noexcept {
  a += b;
}

inline void vec_isub(Vector3d& a, const Vector3d& b) noexcept {
  a -= b;
}

inline Vector4d quat_identity() noexcept {
  return {0.0, 0.0, 0.0, 1.0};
}

inline Vector4d quat_conj(const Vector4d& q) noexcept {
  return {-q.x, -q.y, -q.z, q.w};
}

inline Vector4d quat_mul(const Vector4d& a, const Vector4d& b) noexcept {
  const Vector3d av{a.x, a.y, a.z};
  const Vector3d bv{b.x, b.y, b.z};
  const Vector3d cv = vec_add(vec_add(vec_scale(bv, a.w), vec_scale(av, b.w)), cross(av, bv));
  const double w = a.w * b.w - dot(av, bv);
  return {cv.x, cv.y, cv.z, w};
}


inline Vector4d quat_normalize(const Vector4d& q) noexcept {
  const double n = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  if (n < 1e-12) {
    return quat_identity();
  }
  return {q.x / n, q.y / n, q.z / n, q.w / n};
}

inline Vector4d quat_from_euler_zyx(const double roll, const double pitch, const double yaw){
  const float cr = std::cos(roll * 0.5f);
    const float sr = std::sin(roll * 0.5f);
    const float cp = std::cos(pitch * 0.5f);
    const float sp = std::sin(pitch * 0.5f);
    const float cy = std::cos(yaw * 0.5f);
    const float sy = std::sin(yaw * 0.5f);

    Vector4d q{
        sr * cp * cy - cr * sp * sy,
        cr * sp * cy + sr * cp * sy,
        cr * cp * sy - sr * sp * cy,
        cr * cp * cy + sr * sp * sy,
    };
    return quat_normalize(q);
}

inline Vector4d quat_from_rotvec(const Vector3d& w) noexcept {
  const double theta = norm(w);
  if (theta < 1e-6) {
    return {0.5 * w.x, 0.5 * w.y, 0.5 * w.z, 1.0};
  }
  const double half = 0.5 * theta;
  const double s = std::sin(half) / theta;
  return {w.x * s, w.y * s, w.z * s, std::cos(half)};
}

inline Vector3d quat_rotate(const Vector4d& q, const Vector3d& v) noexcept {
  const Vector3d qv{q.x, q.y, q.z};
  const Vector3d t = vec_scale(cross(qv, v), 2.0);
  return vec_add(v, vec_add(vec_scale(t, q.w), cross(qv, t)));
}

inline double normalize_angle(double angle) noexcept {
  while (angle > pi) {
    angle -= 2.0 * pi;
  }
  while (angle < -pi) {
    angle += 2.0 * pi;
  }
  return angle;
}

inline double unwrap_angle_near(double angle, double reference) noexcept {
  return reference + normalize_angle(angle - reference);
}

inline void quat_to_euler_zyx(
    const Vector4d& q,
    double* roll,
    double* pitch,
    double* yaw) noexcept {
  if (!roll || !pitch || !yaw) {
    return;
  }

  const Vector4d n = quat_normalize(q);
  const double sinr_cosp = 2.0 * (n.w * n.x + n.y * n.z);
  const double cosr_cosp = 1.0 - 2.0 * (n.x * n.x + n.y * n.y);
  *roll = std::atan2(sinr_cosp, cosr_cosp);

  const double sinp = 2.0 * (n.w * n.y - n.z * n.x);
  if (std::abs(sinp) >= 1.0) {
    *pitch = std::copysign(pi * 0.5, sinp);
  } else {
    *pitch = std::asin(sinp);
  }

  const double siny_cosp = 2.0 * (n.w * n.z + n.x * n.y);
  const double cosy_cosp = 1.0 - 2.0 * (n.y * n.y + n.z * n.z);
  *yaw = std::atan2(siny_cosp, cosy_cosp);
}

}  // namespace core
