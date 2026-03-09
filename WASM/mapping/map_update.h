#pragma once

#include "core/pose/se3.h"
#include "mapping/map.h"
#include "sensors/lidar_camera.h"

namespace mapping{
    void build_rerun_frame_from_lidar(const sensors::LidarCameraData& lc_data,
                                      sensors::LidarCameraData& rerun_out,
                                      const core::PoseSE3d& body_to_world);

    void initialize_map(Map& map);

    void update_map_from_lidar(Map& map,
                               const sensors::LidarCameraData& lc_data,
                               MapImage& map_frame,
                               const core::PoseSE3d& body_to_world);
};
