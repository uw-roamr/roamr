#pragma once

#include "core/pose/se3.h"
#include "mapping/map.h"
#include "mapping/map_snapshot.h"
#include "sensors/lidar_camera.h"

namespace mapping{
    void build_rerun_frame_from_lidar(const sensors::LidarCameraData& lc_data,
                                      sensors::LidarCameraData& rerun_out,
                                      const core::PoseSE3d& body_to_world);

    void initialize_map(Map& map);

    bool build_map_snapshot(const Map& map,
                            const core::PoseSE3d& body_to_world,
                            double timestamp,
                            uint64_t map_revision,
                            MapSnapshot* out_snapshot);

    void update_map_from_lidar(Map& map,
                               const sensors::LidarCameraData& lc_data,
                               const core::PoseSE3d& body_to_world);
};
