#pragma once
#include "core/pose/coordinate_frames.h"

namespace core{

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
}; // namespace core
