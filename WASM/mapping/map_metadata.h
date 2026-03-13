#pragma once
#include <stdint.h>
#include "wasm_utils.h"


namespace mapping{

  enum class MapRenderLayerId : int32_t {
    Composite = 0,
    Base = 1,
    Odometry = 2,
    Planning = 3,
    Frontiers = 4,
  };

  struct MapImage {
    double timestamp;
    int32_t width;
    int32_t height;
    int32_t channels;
    uint32_t data_ptr;
    int32_t data_size;
    int32_t layer_id;
  };

  struct OccupancyGridMetadata {
    int32_t width;
    int32_t height;
    double resolution_m;
    double origin_x_m;
    double origin_y_m;
    int32_t origin_initialized;
  };

}; //namespace mapping
