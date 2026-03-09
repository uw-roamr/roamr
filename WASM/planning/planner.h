#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <queue>
#include <string>
#include <utility>
#include <vector>

#include "core/math_utils.h"

namespace planning {

struct GridCoord {
  int32_t x = 0;
  int32_t y = 0;

  bool operator==(const GridCoord& other) const {
    return x == other.x && y == other.y;
  }
};

struct GridMap2D {
  int32_t width = 0;
  int32_t height = 0;
  double resolution_m = 0.0;
  double origin_x_m = 0.0;
  double origin_y_m = 0.0;
  // ROS-like occupancy convention:
  // -1 unknown, [0..100] known occupancy probability.
  std::vector<int8_t> data;

  bool valid() const {
    return width > 0 && height > 0 && resolution_m > 0.0 &&
           data.size() == static_cast<size_t>(width * height);
  }

  bool in_bounds(int32_t x, int32_t y) const {
    return x >= 0 && x < width && y >= 0 && y < height;
  }

  int32_t index(int32_t x, int32_t y) const {
    return y * width + x;
  }
};

struct PlannerConfig {
  int8_t occupied_threshold = 50;
  bool treat_unknown_as_occupied = true;
  bool allow_diagonal = true;
  bool prevent_corner_cutting = true;
  double inflation_radius_m = 0.05;
  bool simplify_path = true;
  bool snap_start_to_free = true;
  bool snap_goal_to_free = true;
  int32_t snap_search_radius_cells = 6;
  int32_t max_expanded_nodes = 250000;
};

struct PlanResult {
  bool success = false;
  std::string message;
  std::vector<GridCoord> path_grid;
  std::vector<core::Vector3d> path_world;
};

inline bool world_to_grid(
    const GridMap2D& map,
    double world_x_m,
    double world_y_m,
    GridCoord* out) {
  if (!out || !map.valid()) {
    return false;
  }
  const int32_t mx = static_cast<int32_t>(
      std::floor((world_x_m - map.origin_x_m) / map.resolution_m));
  const int32_t my = static_cast<int32_t>(
      std::floor((world_y_m - map.origin_y_m) / map.resolution_m));
  if (!map.in_bounds(mx, my)) {
    return false;
  }
  *out = GridCoord{mx, my};
  return true;
}

inline void grid_to_world(
    const GridMap2D& map,
    const GridCoord& cell,
    double* world_x_m,
    double* world_y_m) {
  if (!world_x_m || !world_y_m) {
    return;
  }
  *world_x_m = map.origin_x_m + (static_cast<double>(cell.x) + 0.5) * map.resolution_m;
  *world_y_m = map.origin_y_m + (static_cast<double>(cell.y) + 0.5) * map.resolution_m;
}

inline bool is_cell_blocked(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    int32_t x,
    int32_t y,
    const std::vector<int8_t>* occupancy_override = nullptr) {
  if (!map.in_bounds(x, y)) {
    return true;
  }
  const auto& src = occupancy_override ? *occupancy_override : map.data;
  const int8_t value = src[map.index(x, y)];
  if (value < 0) {
    return cfg.treat_unknown_as_occupied;
  }
  return value >= cfg.occupied_threshold;
}

inline std::vector<int8_t> inflate_obstacles(
    const GridMap2D& map,
    const PlannerConfig& cfg) {
  if (!map.valid() || cfg.inflation_radius_m <= 0.0) {
    return map.data;
  }

  const int32_t radius_cells = static_cast<int32_t>(
      std::ceil(cfg.inflation_radius_m / map.resolution_m));
  if (radius_cells <= 0) {
    return map.data;
  }

  std::vector<GridCoord> offsets;
  offsets.reserve(static_cast<size_t>((2 * radius_cells + 1) * (2 * radius_cells + 1)));
  const int64_t radius_sq = static_cast<int64_t>(radius_cells) * radius_cells;
  for (int32_t dy = -radius_cells; dy <= radius_cells; ++dy) {
    for (int32_t dx = -radius_cells; dx <= radius_cells; ++dx) {
      const int64_t dist_sq = static_cast<int64_t>(dx) * dx +
                              static_cast<int64_t>(dy) * dy;
      if (dist_sq <= radius_sq) {
        offsets.push_back(GridCoord{dx, dy});
      }
    }
  }

  std::vector<int8_t> inflated = map.data;
  for (int32_t y = 0; y < map.height; ++y) {
    for (int32_t x = 0; x < map.width; ++x) {
      const int8_t cell = map.data[map.index(x, y)];
      const bool is_occupied = cell >= cfg.occupied_threshold;
      if (!is_occupied) {
        continue;
      }
      for (const GridCoord& d : offsets) {
        const int32_t nx = x + d.x;
        const int32_t ny = y + d.y;
        if (!map.in_bounds(nx, ny)) {
          continue;
        }
        int8_t& out = inflated[map.index(nx, ny)];
        // Keep unknown cells unknown if they are unknown in the source map.
        if (map.data[map.index(nx, ny)] < 0) {
          continue;
        }
        out = 100;
      }
    }
  }
  return inflated;
}

inline bool line_of_sight_free(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy,
    const GridCoord& a,
    const GridCoord& b) {
  int32_t x0 = a.x;
  int32_t y0 = a.y;
  const int32_t x1 = b.x;
  const int32_t y1 = b.y;
  const int32_t dx = std::abs(x1 - x0);
  const int32_t sx = x0 < x1 ? 1 : -1;
  const int32_t dy = -std::abs(y1 - y0);
  const int32_t sy = y0 < y1 ? 1 : -1;
  int32_t err = dx + dy;

  while (true) {
    if (is_cell_blocked(map, cfg, x0, y0, &occupancy)) {
      return false;
    }
    if (x0 == x1 && y0 == y1) {
      return true;
    }
    const int32_t e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x0 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y0 += sy;
    }
  }
}

inline std::vector<GridCoord> simplify_grid_path(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy,
    const std::vector<GridCoord>& input_path) {
  if (input_path.size() <= 2) {
    return input_path;
  }

  std::vector<GridCoord> simplified;
  simplified.reserve(input_path.size());
  size_t anchor = 0;
  simplified.push_back(input_path[anchor]);

  while (anchor + 1 < input_path.size()) {
    size_t best = anchor + 1;
    for (size_t candidate = input_path.size() - 1; candidate > best; --candidate) {
      if (line_of_sight_free(
              map, cfg, occupancy, input_path[anchor], input_path[candidate])) {
        best = candidate;
        break;
      }
    }
    simplified.push_back(input_path[best]);
    anchor = best;
  }
  return simplified;
}

inline bool find_nearest_free_cell(
    const GridMap2D& map,
    const PlannerConfig& cfg,
    const std::vector<int8_t>& occupancy,
    const GridCoord& seed,
    int32_t max_radius_cells,
    GridCoord* out) {
  if (!out) {
    return false;
  }
  if (map.in_bounds(seed.x, seed.y) &&
      !is_cell_blocked(map, cfg, seed.x, seed.y, &occupancy)) {
    *out = seed;
    return true;
  }
  const int32_t max_radius = std::max(0, max_radius_cells);
  for (int32_t radius = 1; radius <= max_radius; ++radius) {
    for (int32_t dx = -radius; dx <= radius; ++dx) {
      const int32_t x = seed.x + dx;
      const int32_t y_top = seed.y - radius;
      const int32_t y_bot = seed.y + radius;
      if (map.in_bounds(x, y_top) &&
          !is_cell_blocked(map, cfg, x, y_top, &occupancy)) {
        *out = GridCoord{x, y_top};
        return true;
      }
      if (map.in_bounds(x, y_bot) &&
          !is_cell_blocked(map, cfg, x, y_bot, &occupancy)) {
        *out = GridCoord{x, y_bot};
        return true;
      }
    }
    for (int32_t dy = -radius + 1; dy <= radius - 1; ++dy) {
      const int32_t y = seed.y + dy;
      const int32_t x_left = seed.x - radius;
      const int32_t x_right = seed.x + radius;
      if (map.in_bounds(x_left, y) &&
          !is_cell_blocked(map, cfg, x_left, y, &occupancy)) {
        *out = GridCoord{x_left, y};
        return true;
      }
      if (map.in_bounds(x_right, y) &&
          !is_cell_blocked(map, cfg, x_right, y, &occupancy)) {
        *out = GridCoord{x_right, y};
        return true;
      }
    }
  }
  return false;
}

class AStarPlanner {
 public:
  explicit AStarPlanner(const PlannerConfig& cfg = {}) : cfg_(cfg) {}

  void set_config(const PlannerConfig& cfg) { cfg_ = cfg; }
  const PlannerConfig& config() const { return cfg_; }

  PlanResult plan_to_point(
      const GridMap2D& map,
      const core::Vector3d& start_world,
      const core::Vector3d& goal_world) const {
    return plan_to_point(
        map,
        start_world.x,
        start_world.y,
        goal_world.x,
        goal_world.y);
  }

  PlanResult plan_to_point(
      const GridMap2D& map,
      double start_x_m,
      double start_y_m,
      double goal_x_m,
      double goal_y_m) const {
    PlanResult result;
    if (!map.valid()) {
      result.message = "invalid occupancy grid";
      return result;
    }

    GridCoord start{};
    GridCoord goal{};
    if (!world_to_grid(map, start_x_m, start_y_m, &start) ||
        !world_to_grid(map, goal_x_m, goal_y_m, &goal)) {
      result.message = "start or goal outside map bounds";
      return result;
    }

    return plan_to_grid(map, start, goal);
  }

  PlanResult plan_to_grid(
      const GridMap2D& map,
      const GridCoord& start_in,
      const GridCoord& goal_in) const {
    PlanResult result;
    if (!map.valid()) {
      result.message = "invalid occupancy grid";
      return result;
    }

    if (!map.in_bounds(start_in.x, start_in.y) ||
        !map.in_bounds(goal_in.x, goal_in.y)) {
      result.message = "start or goal outside map bounds";
      return result;
    }

    const std::vector<int8_t> occupancy = inflate_obstacles(map, cfg_);
    GridCoord start = start_in;
    GridCoord goal = goal_in;

    if (is_cell_blocked(map, cfg_, start.x, start.y, &occupancy)) {
      if (!cfg_.snap_start_to_free ||
          !find_nearest_free_cell(
              map,
              cfg_,
              occupancy,
              start,
              cfg_.snap_search_radius_cells,
              &start)) {
        result.message = "start cell is occupied";
        return result;
      }
    }
    if (is_cell_blocked(map, cfg_, goal.x, goal.y, &occupancy)) {
      if (!cfg_.snap_goal_to_free ||
          !find_nearest_free_cell(
              map,
              cfg_,
              occupancy,
              goal,
              cfg_.snap_search_radius_cells,
              &goal)) {
        result.message = "goal cell is occupied";
        return result;
      }
    }

    constexpr int32_t kCardinalDx[4] = {1, -1, 0, 0};
    constexpr int32_t kCardinalDy[4] = {0, 0, 1, -1};
    constexpr int32_t kAllDx[8] = {1, -1, 0, 0, 1, -1, 1, -1};
    constexpr int32_t kAllDy[8] = {0, 0, 1, -1, 1, -1, -1, 1};
    const int32_t neighbor_count = cfg_.allow_diagonal ? 8 : 4;

    struct OpenNode {
      int32_t idx = -1;
      double f = 0.0;
      double g = 0.0;
    };
    struct MinHeapByF {
      bool operator()(const OpenNode& a, const OpenNode& b) const {
        if (a.f == b.f) {
          return a.g > b.g;
        }
        return a.f > b.f;
      }
    };

    const int32_t total_cells = map.width * map.height;
    const int32_t start_idx = map.index(start.x, start.y);
    const int32_t goal_idx = map.index(goal.x, goal.y);
    const double kInf = std::numeric_limits<double>::infinity();

    std::vector<double> g_cost(static_cast<size_t>(total_cells), kInf);
    std::vector<int32_t> came_from(static_cast<size_t>(total_cells), -1);
    std::vector<uint8_t> closed(static_cast<size_t>(total_cells), 0);
    std::priority_queue<OpenNode, std::vector<OpenNode>, MinHeapByF> open_set;

    auto heuristic = [&goal](int32_t x, int32_t y) -> double {
      const double dx = static_cast<double>(x - goal.x);
      const double dy = static_cast<double>(y - goal.y);
      return std::sqrt(dx * dx + dy * dy);
    };

    g_cost[static_cast<size_t>(start_idx)] = 0.0;
    open_set.push(OpenNode{start_idx, heuristic(start.x, start.y), 0.0});

    int32_t expanded_nodes = 0;
    bool found = false;

    while (!open_set.empty()) {
      const OpenNode node = open_set.top();
      open_set.pop();

      if (closed[static_cast<size_t>(node.idx)] != 0) {
        continue;
      }
      closed[static_cast<size_t>(node.idx)] = 1;
      ++expanded_nodes;

      if (expanded_nodes > cfg_.max_expanded_nodes) {
        result.message = "planning aborted: expansion limit reached";
        return result;
      }

      if (node.idx == goal_idx) {
        found = true;
        break;
      }

      const int32_t cx = node.idx % map.width;
      const int32_t cy = node.idx / map.width;

      for (int32_t i = 0; i < neighbor_count; ++i) {
        const int32_t dx = cfg_.allow_diagonal ? kAllDx[i] : kCardinalDx[i];
        const int32_t dy = cfg_.allow_diagonal ? kAllDy[i] : kCardinalDy[i];
        const int32_t nx = cx + dx;
        const int32_t ny = cy + dy;
        if (!map.in_bounds(nx, ny) ||
            is_cell_blocked(map, cfg_, nx, ny, &occupancy)) {
          continue;
        }

        const bool diagonal = (dx != 0 && dy != 0);
        if (diagonal && cfg_.prevent_corner_cutting) {
          if (is_cell_blocked(map, cfg_, cx + dx, cy, &occupancy) ||
              is_cell_blocked(map, cfg_, cx, cy + dy, &occupancy)) {
            continue;
          }
        }

        const int32_t nidx = map.index(nx, ny);
        if (closed[static_cast<size_t>(nidx)] != 0) {
          continue;
        }

        const double step_cost = diagonal ? 1.4142135623730951 : 1.0;
        const double tentative_g = g_cost[static_cast<size_t>(node.idx)] + step_cost;
        if (tentative_g >= g_cost[static_cast<size_t>(nidx)]) {
          continue;
        }

        came_from[static_cast<size_t>(nidx)] = node.idx;
        g_cost[static_cast<size_t>(nidx)] = tentative_g;
        const double h = heuristic(nx, ny);
        const double f = tentative_g + h;
        open_set.push(OpenNode{nidx, f, tentative_g});
      }
    }

    if (!found) {
      result.message = "no path found";
      return result;
    }

    std::vector<GridCoord> path_grid_reversed;
    for (int32_t idx = goal_idx; idx >= 0; idx = came_from[static_cast<size_t>(idx)]) {
      path_grid_reversed.push_back(GridCoord{idx % map.width, idx / map.width});
      if (idx == start_idx) {
        break;
      }
    }

    if (path_grid_reversed.empty() || !(path_grid_reversed.back() == start)) {
      result.message = "failed to reconstruct path";
      return result;
    }

    result.path_grid.assign(path_grid_reversed.rbegin(), path_grid_reversed.rend());
    if (cfg_.simplify_path) {
      result.path_grid = simplify_grid_path(map, cfg_, occupancy, result.path_grid);
    }

    result.path_world.reserve(result.path_grid.size());
    for (const GridCoord& c : result.path_grid) {
      double wx = 0.0;
      double wy = 0.0;
      grid_to_world(map, c, &wx, &wy);
      result.path_world.push_back(core::Vector3d{wx, wy, 0.0});
    }

    result.success = true;
    result.message = "ok";
    return result;
  }

 private:
  PlannerConfig cfg_;
};

}  // namespace planning
