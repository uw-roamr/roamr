#pragma once
#include "core/coordinate_frames.h"
#include "core/wasm_utils.h"

namespace sensors{
    struct IMUData {
        double timestamp;
        double acc_x, acc_y, acc_z;
        // double gyro_timestamp;
        double gyro_x, gyro_y, gyro_z;
        // double att_timestamp;
        // double quat_x, quat_y, quat_z, quat_w;
        core::CoordinateFrameId_t frame_id; // CoordinateFrameId: 0=RDF, 1=FLU
        // double mag_x, mag_y, mag_z; // unused, currently targeting indoor environments and simple fusion
    };

    WASM_IMPORT("host", "read_imu") void read_imu(IMUData* data);

    constexpr double IMURefreshHz = 100.0;
    constexpr int IMUIntervalMs = static_cast<int>(1000.0 / IMURefreshHz) / 2.0;
}; //namespace sensors
