#pragma once
#include "core/pose/coordinate_frames.h"

namespace core{

    struct PoseSE3d{
    Vector3d translation;
    Vector4d quaternion;

    PoseSE3d(){
      translation = {};
      quaternion = quat_identity();
    }
    PoseSE3d(const Vector3d &translation, const Vector4d &quaternion)
        : translation(translation),
          quaternion(quat_normalize(quaternion)) {
    }

    PoseSE3d operator*(const PoseSE3d& rhs) const noexcept {
      return PoseSE3d{
          translation + quat_rotate(quaternion, rhs.translation),
          quat_normalize(quat_mul(quaternion, rhs.quaternion))};
    }

    Vector3d operator*(const Vector3d& point) const noexcept {
      return quat_rotate(quaternion, point) + translation;
    }

    PoseSE3d& operator*=(const PoseSE3d& rhs) noexcept {
      *this = *this * rhs;
      return *this;
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
}; // namespace core
