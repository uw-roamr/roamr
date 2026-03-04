#pragma once

#include "core/coordinate_frames.h"
#include "mapping/map_api.h"
#include "sensors/lidar_camera.h"

namespace mapping{
    void update_map_from_lidar(const sensors::LidarCameraData& lc_data,
                               MapFrame& map_frame,
                               sensors::LidarCameraData* rerun_out,
                               bool update_map,
                               bool& map_initialized,
                               const core::PoseSE3d& body_to_world);
};
