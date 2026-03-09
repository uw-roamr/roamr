#pragma once
#include <stdint.h>
#include "wasm_utils.h"


namespace mapping{

  struct MapFrameMetadata {
    double timestamp;
    int32_t width;
    int32_t height;
    int32_t channels;
    uint32_t data_ptr;
    int32_t data_size;
  };

  struct OccupancyGridMetadata {
    int32_t width;
    int32_t height;
    double resolution_m;
    double origin_x_m;
    double origin_y_m;
    int32_t origin_initialized;
  };

  constexpr double mapMinIntervalSeconds = 0.1; // seconds


  WASM_IMPORT("host", "rerun_log_map_frame") void rerun_log_map_frame(const MapFrameMetadata *frame);
}; //namespace mapping
