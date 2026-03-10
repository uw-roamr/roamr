#pragma once

#include <cstdint>
#include <vector>

#include "mapping/map_snapshot.h"
#include "planning/planner.h"

namespace mapping {

inline planning::PlannerConfig default_navigation_costmap_config() {
  planning::PlannerConfig cfg;
  cfg.occupied_threshold = 50;
  cfg.treat_unknown_as_occupied = true;
  cfg.allow_diagonal = true;
  cfg.prevent_corner_cutting = true;
  cfg.inflation_radius_m = 0.1;
  cfg.simplify_path = true;
  cfg.snap_start_to_free = true;
  cfg.snap_goal_to_free = true;
  cfg.snap_search_radius_cells = 10;
  return cfg;
}

struct InflatedCostmap {
  planning::GridMap2D grid;
  planning::PlannerConfig config;
  std::vector<int8_t> inflated_occupancy;

  bool valid() const {
    return grid.valid() &&
           inflated_occupancy.size() ==
               static_cast<size_t>(grid.width * grid.height);
  }

  bool is_inflated_blocked(int32_t x, int32_t y) const {
    return planning::is_cell_blocked(
        grid, config, x, y, &inflated_occupancy);
  }

  bool is_source_occupied(int32_t x, int32_t y) const {
    return planning::is_cell_blocked(grid, config, x, y, &grid.data);
  }
};

inline bool load_snapshot_grid(
    const MapSnapshot& snapshot,
    planning::GridMap2D* out_map) {
  if (!out_map) {
    return false;
  }
  const OccupancyGridMetadata& meta = snapshot.meta;
  if (meta.width <= 0 || meta.height <= 0 || meta.resolution_m <= 0.0) {
    return false;
  }
  out_map->width = meta.width;
  out_map->height = meta.height;
  out_map->resolution_m = meta.resolution_m;
  out_map->origin_x_m = meta.origin_x_m;
  out_map->origin_y_m = meta.origin_y_m;
  out_map->data = snapshot.occupancy;
  return out_map->valid();
}

inline bool build_inflated_costmap(
    const MapSnapshot& snapshot,
    const planning::PlannerConfig& cfg,
    InflatedCostmap* out_costmap) {
  if (!out_costmap) {
    return false;
  }
  planning::GridMap2D grid;
  if (!load_snapshot_grid(snapshot, &grid)) {
    return false;
  }
  out_costmap->grid = std::move(grid);
  out_costmap->config = cfg;
  out_costmap->inflated_occupancy =
      planning::inflate_obstacles(out_costmap->grid, out_costmap->config);
  return out_costmap->valid();
}

}  // namespace mapping
