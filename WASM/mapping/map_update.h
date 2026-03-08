#pragma once

#include "core/coordinate_frames.h"
#include "mapping/map_api.h"
#include "sensors/lidar_camera.h"

namespace mapping{
    void build_rerun_frame_from_lidar(const sensors::LidarCameraData& lc_data,
                                      sensors::LidarCameraData& rerun_out,
                                      const core::PoseSE3d& body_to_world);

    void initialize_map();

    void update_map_from_lidar(const sensors::LidarCameraData& lc_data,
                               MapFrame& map_frame,
                               const core::PoseSE3d& body_to_world);
};
