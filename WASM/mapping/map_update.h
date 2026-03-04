#pragma once

#include "core/coordinate_frames.h"
#include "mapping/map_api.h"
#include "sensors/lidar_camera.h"

namespace mapping{
    void build_rerun_frame_from_lidar(const sensors::LidarCameraData& lc_data,
                                      sensors::LidarCameraData& rerun_out);

    void update_map_from_lidar(const sensors::LidarCameraData& lc_data,
                               MapFrame& map_frame,
                               bool& map_initialized,
                               const core::Vector4d& q_body_to_world,
                               const core::Vector3d& t_body_to_world);
};
