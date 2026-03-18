#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <sstream>
#include <string>
#include <thread>

#include "controls/motors.h"
#include "controls/path_following.h"
#include "core/telemetry.h"
#include "ml/model.h"
#include "planning/planner.h"
#include "sensors/lidar_camera.h"
#include "sensors/wheel_odometry.h"

namespace {

constexpr const char* kDefaultManifestPath = "detector_bundle/manifest.json";
// Update this to match the exported stop-sign class in your model bundle.
constexpr int32_t kStopSignClassId = 13;
constexpr float kStopScoreThreshold = 0.4f;
constexpr int32_t kStopHoldMs = 250;
constexpr int kLoopSleepMs = 100;
constexpr int kIdleRetrySleepMs = 50;
constexpr int kPathFollowHoldMs = 120;
constexpr double kStopSignStandOffM = 0.05;
constexpr double kMinApproachDistanceM = 0.07;
constexpr double kLocalMapResolutionM = 0.025;
constexpr double kLocalMapHalfExtentMinM = 0.75;
constexpr double kLocalMapHalfExtentMarginM = 0.35;
constexpr double kLocalMapHalfExtentMaxM = 2.0;
constexpr double kStartClearRadiusM = 0.08;
constexpr double kGoalClearRadiusM = 0.03;
constexpr double kObstacleIgnoreRadiusM = 0.08;
constexpr double kObstacleMinZ = -0.10;
constexpr double kObstacleMaxZ = 1.80;
constexpr double kFollowLogIntervalSec = 0.5;

struct BoundingBoxPixels {
  int32_t x_min = 0;
  int32_t y_min = 0;
  int32_t x_max = 0;
  int32_t y_max = 0;
  int32_t center_x = 0;
  int32_t center_y = 0;
};

struct LidarBoundingBoxQueryResult {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
  int32_t pixel_x = 0;
  int32_t pixel_y = 0;
  int32_t matched_points = 0;
  bool used_bbox_match = false;
  double lidar_timestamp = 0.0;
};

enum class DemoState : uint8_t {
  kSearching = 0,
  kFollowingPath = 1,
  kStopped = 2,
};

// Keep the large LiDAR payload off the WASM stack.
static sensors::LidarCameraDataV2 g_lidar_data{};

void write_stop_command() {
  const controls::MotorCommand stop{0, 0, kStopHoldMs};
  controls::write_motors(&stop);
}

planning::PlannerConfig build_stop_sign_planner_config() {
  planning::PlannerConfig cfg;
  cfg.occupied_threshold = 50;
  cfg.treat_unknown_as_occupied = false;
  cfg.allow_diagonal = true;
  cfg.prevent_corner_cutting = true;
  cfg.inflation_radius_m = 0.02;
  cfg.simplify_path = true;
  cfg.snap_start_to_free = true;
  cfg.snap_goal_to_free = true;
  cfg.snap_search_radius_cells = 4;
  cfg.max_expanded_nodes = 60000;
  return cfg;
}

controls::PathFollowerConfig build_stop_sign_path_follower_config() {
  controls::PathFollowerConfig cfg;
  cfg.lookahead_m = 0.06;
  cfg.waypoint_reached_m = 0.03;
  cfg.goal_tolerance_m = 0.03;
  cfg.goal_heading_tolerance_rad = 0.35;
  cfg.start_heading_align_tolerance_rad = 0.18;
  cfg.slow_down_near_goal = true;
  cfg.allow_reverse = false;
  return cfg;
}

bool find_best_stop_sign_detection(
    const ml::RunLatestCameraFrameRequest& request,
    ml::Detection* out_detection = nullptr,
    float* out_best_score = nullptr) {
  bool found = false;
  ml::Detection best_detection{};
  float best_score = 0.0f;
  const int32_t max_count = static_cast<int32_t>(ml::kMaxDetections);
  const int32_t detection_count =
      std::max<int32_t>(0, std::min<int32_t>(request.detection_count, max_count));
  for (int32_t i = 0; i < detection_count; ++i) {
    const ml::Detection& detection = request.detections[i];
    if (detection.class_id != kStopSignClassId) {
      continue;
    }
    if (!found || detection.score > best_score) {
      best_score = detection.score;
      best_detection = detection;
      found = true;
    }
  }
  if (out_best_score) {
    *out_best_score = best_score;
  }
  if (out_detection && found && best_score >= kStopScoreThreshold) {
    *out_detection = best_detection;
  }
  return found && best_score >= kStopScoreThreshold;
}

bool is_normalized_box(const ml::Detection& detection) {
  return detection.x_min >= -0.5f && detection.y_min >= -0.5f &&
         detection.x_max <= 1.5f && detection.y_max <= 1.5f;
}

bool detection_to_bounding_box_pixels(
    const ml::RunLatestCameraFrameRequest& request,
    const ml::Detection& detection,
    BoundingBoxPixels* out_box) {
  if (!out_box || request.image_width <= 0 || request.image_height <= 0) {
    return false;
  }

  const bool normalized = is_normalized_box(detection);
  const float x_scale =
      normalized ? static_cast<float>(request.image_width) : 1.0f;
  const float y_scale =
      normalized ? static_cast<float>(request.image_height) : 1.0f;

  const float raw_x0 = detection.x_min * x_scale;
  const float raw_y0 = detection.y_min * y_scale;
  const float raw_x1 = detection.x_max * x_scale;
  const float raw_y1 = detection.y_max * y_scale;

  const int32_t max_x = std::max(0, request.image_width - 1);
  const int32_t max_y = std::max(0, request.image_height - 1);
  const int32_t x_min = std::clamp(
      static_cast<int32_t>(std::floor(std::min(raw_x0, raw_x1))), 0, max_x);
  const int32_t y_min = std::clamp(
      static_cast<int32_t>(std::floor(std::min(raw_y0, raw_y1))), 0, max_y);
  const int32_t x_max = std::clamp(
      static_cast<int32_t>(std::ceil(std::max(raw_x0, raw_x1))), 0, max_x);
  const int32_t y_max = std::clamp(
      static_cast<int32_t>(std::ceil(std::max(raw_y0, raw_y1))), 0, max_y);

  if (x_min > x_max || y_min > y_max) {
    return false;
  }

  out_box->x_min = x_min;
  out_box->y_min = y_min;
  out_box->x_max = x_max;
  out_box->y_max = y_max;
  out_box->center_x = x_min + (x_max - x_min) / 2;
  out_box->center_y = y_min + (y_max - y_min) / 2;
  return true;
}

bool query_lidar_bbox_coordinates(
    const sensors::LidarCameraDataV2& lidar_data,
    const BoundingBoxPixels& box,
    LidarBoundingBoxQueryResult* out_result) {
  if (!out_result) {
    return false;
  }

  const size_t point_count = std::min(
      lidar_data.points_size / sensors::float_per_point,
      lidar_data.pixel_coords_size / sensors::pixel_coord_components);
  if (point_count == 0) {
    return false;
  }

  bool found_any = false;
  bool found_in_box = false;
  int32_t matched_points = 0;
  float best_any_dist2 = std::numeric_limits<float>::infinity();
  float best_box_dist2 = std::numeric_limits<float>::infinity();
  LidarBoundingBoxQueryResult best_any{};
  LidarBoundingBoxQueryResult best_box{};

  for (size_t point_idx = 0; point_idx < point_count; ++point_idx) {
    const size_t point_base = point_idx * sensors::float_per_point;
    const size_t pixel_base = point_idx * sensors::pixel_coord_components;
    const int32_t pixel_x = lidar_data.pixel_coords[pixel_base + 0];
    const int32_t pixel_y = lidar_data.pixel_coords[pixel_base + 1];
    const float dx = static_cast<float>(pixel_x - box.center_x);
    const float dy = static_cast<float>(pixel_y - box.center_y);
    const float dist2 = dx * dx + dy * dy;

    LidarBoundingBoxQueryResult candidate{};
    candidate.x = lidar_data.points[point_base + 0];
    candidate.y = lidar_data.points[point_base + 1];
    candidate.z = lidar_data.points[point_base + 2];
    candidate.pixel_x = pixel_x;
    candidate.pixel_y = pixel_y;
    candidate.lidar_timestamp = lidar_data.timestamp;

    if (!found_any || dist2 < best_any_dist2) {
      best_any = candidate;
      best_any_dist2 = dist2;
      found_any = true;
    }

    if (pixel_x < box.x_min || pixel_x > box.x_max || pixel_y < box.y_min ||
        pixel_y > box.y_max) {
      continue;
    }

    ++matched_points;
    if (!found_in_box || dist2 < best_box_dist2) {
      best_box = candidate;
      best_box_dist2 = dist2;
      found_in_box = true;
      best_box.used_bbox_match = true;
    }
  }

  if (found_in_box) {
    best_box.matched_points = matched_points;
    *out_result = best_box;
    return true;
  }

  if (!found_any) {
    return false;
  }

  best_any.matched_points = 0;
  best_any.used_bbox_match = false;
  *out_result = best_any;
  return true;
}

bool compute_stop_sign_goal(
    const LidarBoundingBoxQueryResult& sign_query,
    core::Vector3d* out_goal) {
  if (!out_goal) {
    return false;
  }
  const double planar_distance = std::hypot(sign_query.x, sign_query.y);
  if (!std::isfinite(planar_distance) ||
      planar_distance < kMinApproachDistanceM) {
    return false;
  }

  const double goal_distance =
      std::max(0.0, planar_distance - kStopSignStandOffM);
  const double scale = goal_distance / planar_distance;
  *out_goal = core::Vector3d{
      static_cast<double>(sign_query.x) * scale,
      static_cast<double>(sign_query.y) * scale,
      0.0};
  return true;
}

bool build_local_stop_sign_map(
    const sensors::LidarCameraDataV2& lidar_data,
    const core::Vector3d& goal_world,
    planning::GridMap2D* out_map) {
  if (!out_map) {
    return false;
  }

  const double half_extent = std::clamp(
      std::max(
          kLocalMapHalfExtentMinM,
          std::max(std::abs(goal_world.x), std::abs(goal_world.y)) +
              kLocalMapHalfExtentMarginM),
      kLocalMapHalfExtentMinM,
      kLocalMapHalfExtentMaxM);
  const int32_t width = static_cast<int32_t>(
      std::ceil((2.0 * half_extent) / kLocalMapResolutionM));
  const int32_t height = width;
  if (width <= 2 || height <= 2) {
    return false;
  }

  out_map->width = width;
  out_map->height = height;
  out_map->resolution_m = kLocalMapResolutionM;
  out_map->origin_x_m = -half_extent;
  out_map->origin_y_m = -half_extent;
  out_map->data.assign(static_cast<size_t>(width * height), 0);

  const size_t point_count = lidar_data.points_size / sensors::float_per_point;
  for (size_t point_idx = 0; point_idx < point_count; ++point_idx) {
    const size_t point_base = point_idx * sensors::float_per_point;
    const double x = lidar_data.points[point_base + 0];
    const double y = lidar_data.points[point_base + 1];
    const double z = lidar_data.points[point_base + 2];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
      continue;
    }
    if (std::hypot(x, y) < kObstacleIgnoreRadiusM) {
      continue;
    }
    if (z < kObstacleMinZ || z > kObstacleMaxZ) {
      continue;
    }

    planning::GridCoord cell{};
    if (!planning::world_to_grid(*out_map, x, y, &cell)) {
      continue;
    }
    out_map->data[out_map->index(cell.x, cell.y)] = 100;
  }

  auto clear_radius = [&](double wx, double wy, double radius_m) {
    const int32_t radius_cells = static_cast<int32_t>(
        std::ceil(radius_m / out_map->resolution_m));
    planning::GridCoord center{};
    if (!planning::world_to_grid(*out_map, wx, wy, &center)) {
      return;
    }
    for (int32_t dy = -radius_cells; dy <= radius_cells; ++dy) {
      for (int32_t dx = -radius_cells; dx <= radius_cells; ++dx) {
        const int32_t cx = center.x + dx;
        const int32_t cy = center.y + dy;
        if (!out_map->in_bounds(cx, cy)) {
          continue;
        }
        const double dist = std::hypot(
            static_cast<double>(dx) * out_map->resolution_m,
            static_cast<double>(dy) * out_map->resolution_m);
        if (dist <= radius_m) {
          out_map->data[out_map->index(cx, cy)] = 0;
        }
      }
    }
  };

  clear_radius(0.0, 0.0, kStartClearRadiusM);
  clear_radius(goal_world.x, goal_world.y, kGoalClearRadiusM);
  return out_map->valid();
}

bool plan_path_to_stop_sign(
    const sensors::LidarCameraDataV2& lidar_data,
    const LidarBoundingBoxQueryResult& sign_query,
    std::vector<core::Vector3d>* out_path_world,
    core::Vector3d* out_goal_world,
    std::string* out_message) {
  if (out_message) {
    out_message->clear();
  }
  if (!out_path_world || !out_goal_world) {
    if (out_message) {
      *out_message = "invalid plan outputs";
    }
    return false;
  }

  core::Vector3d goal_world{};
  if (!compute_stop_sign_goal(sign_query, &goal_world)) {
    if (out_message) {
      *out_message = "stop sign target too close or invalid";
    }
    return false;
  }

  planning::GridMap2D map{};
  if (!build_local_stop_sign_map(lidar_data, goal_world, &map)) {
    if (out_message) {
      *out_message = "failed to build local occupancy map";
    }
    return false;
  }

  planning::AStarPlanner planner(build_stop_sign_planner_config());
  const planning::PlanResult result =
      planner.plan_to_point(map, 0.0, 0.0, goal_world.x, goal_world.y);
  if (!result.success || result.path_world.empty()) {
    if (out_message) {
      *out_message = result.message.empty() ? "planner failed" : result.message;
    }
    return false;
  }

  *out_goal_world = goal_world;
  *out_path_world = result.path_world;
  if (out_message) {
    std::ostringstream msg;
    msg << "planned " << result.path_world.size() << " waypoints";
    if (!result.message.empty()) {
      msg << " (" << result.message << ")";
    }
    *out_message = msg.str();
  }
  return true;
}

}  // namespace

int main() {
  wasm_log_line("[stop_sign] loading model bundle");

  int32_t model_id = 0;
  const int32_t open_status = ml::open_model(kDefaultManifestPath, &model_id);
  if (open_status != ml::kSuccess) {
    std::ostringstream log;
    log << "[stop_sign] failed to open model path=" << kDefaultManifestPath
        << " status=" << ml::status_name(open_status)
        << " code=" << open_status;
    wasm_log_line(log.str());
    return 1;
  }

  {
    std::ostringstream log;
    log << "[stop_sign] model ready id=" << model_id
        << " class_id=" << kStopSignClassId
        << " threshold=" << kStopScoreThreshold;
    wasm_log_line(log.str());
  }

  controls::MotorController motors;
  controls::PathFollower path_follower(build_stop_sign_path_follower_config());
  std::vector<core::Vector3d> active_path_world;
  core::Vector3d active_goal_world{};
  core::PoseSE2d wheel_pose{};
  sensors::WheelOdometryData odom{};
  DemoState state = DemoState::kSearching;
  bool stop_latched = false;
  double last_log_timestamp = -1.0;
  double last_processed_frame_timestamp = -1.0;
  double last_follow_log_timestamp = -1.0;
  bool wheel_odom_origin_initialized = false;
  int32_t last_odom_seq = std::numeric_limits<int32_t>::min();

  while (true) {
    if (state == DemoState::kFollowingPath) {
      sensors::read_wheel_odometry(&odom);
      if (odom.seq < 0 || odom.timestamp <= 0.0 || odom.sample_period_ms <= 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kIdleRetrySleepMs));
        continue;
      }
      if (odom.seq == last_odom_seq) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kIdleRetrySleepMs));
        continue;
      }
      last_odom_seq = odom.seq;

      if (!wheel_odom_origin_initialized) {
        wheel_odom_origin_initialized = true;
        continue;
      }

      sensors::integrate_wheel_odometry(odom, wheel_pose);
      const controls::Pose2D pose{
          wheel_pose.x,
          wheel_pose.y,
          wheel_pose.theta};
      const double dt_seconds = std::max(
          1e-3,
          static_cast<double>(odom.sample_period_ms) * 1e-3);
      const controls::PathFollowerStatus follow_status =
          path_follower.update(pose, dt_seconds, kPathFollowHoldMs);
      if (follow_status.goal_reached) {
        motors.stop();
        state = DemoState::kStopped;
        wasm_log_line("[stop_sign] reached 5cm standoff; stopped");
        continue;
      }

      motors.drive_twist(follow_status.command, odom);
      if (last_follow_log_timestamp < 0.0 ||
          (odom.timestamp - last_follow_log_timestamp) >= kFollowLogIntervalSec) {
        std::ostringstream follow_log;
        follow_log << "[stop_sign] following pose=("
                   << pose.x << "," << pose.y << "," << pose.yaw
                   << ") goal=(" << active_goal_world.x << ","
                   << active_goal_world.y << ") target_index="
                   << follow_status.target_index
                   << " dist_error=" << follow_status.distance_error_m
                   << " heading_error=" << follow_status.heading_error_rad
                   << " cmd=(" << follow_status.command.v_mps << ","
                   << follow_status.command.omega_rad_s << ")";
        wasm_log_line(follow_log.str());
        last_follow_log_timestamp = odom.timestamp;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(kIdleRetrySleepMs));
      continue;
    }

    if (state == DemoState::kStopped) {
      motors.stop();
      std::this_thread::sleep_for(std::chrono::milliseconds(kLoopSleepMs));
      continue;
    }

    ml::RunLatestCameraFrameRequest request{};
    const int32_t status = ml::run_latest_camera_frame(model_id, &request);

    if (status == ml::kNoFrameAvailable) {
      std::this_thread::sleep_for(std::chrono::milliseconds(kIdleRetrySleepMs));
      continue;
    }

    if (status != ml::kSuccess) {
      std::ostringstream log;
      log << "[stop_sign] inference failed status=" << ml::status_name(status)
          << " code=" << status;
      wasm_log_line(log.str());
      std::this_thread::sleep_for(std::chrono::milliseconds(kLoopSleepMs));
      continue;
    }

    if (request.frame_timestamp <= 0.0 ||
        request.frame_timestamp == last_processed_frame_timestamp) {
      std::this_thread::sleep_for(std::chrono::milliseconds(kIdleRetrySleepMs));
      continue;
    }
    last_processed_frame_timestamp = request.frame_timestamp;

    ml::Detection best_detection{};
    float best_score = 0.0f;
    const bool saw_stop =
        find_best_stop_sign_detection(request, &best_detection, &best_score);
    if (saw_stop) {
      if (!stop_latched || request.frame_timestamp - last_log_timestamp >= 1.0) {
        wasm_log_line("Stop sign detected");

        std::ostringstream log;
        log << "[stop_sign] score=" << best_score
            << " detections=" << request.detection_count;

        BoundingBoxPixels box{};
        if (detection_to_bounding_box_pixels(request, best_detection, &box)) {
          log << " bbox=(" << box.x_min << "," << box.y_min << ")-(" << box.x_max
              << "," << box.y_max << ")"
              << " center=(" << box.center_x << "," << box.center_y << ")";

          sensors::read_lidar_camera_v2(&g_lidar_data);
          LidarBoundingBoxQueryResult lidar_query{};
          if (query_lidar_bbox_coordinates(g_lidar_data, box, &lidar_query)) {
            log << " lidar_xyz=(" << lidar_query.x << "," << lidar_query.y
                << "," << lidar_query.z << ")"
                << " lidar_pixel=(" << lidar_query.pixel_x << ","
                << lidar_query.pixel_y << ")"
                << " bbox_points=" << lidar_query.matched_points
                << " lidar_t=" << lidar_query.lidar_timestamp
                << " frame_dt=" << (lidar_query.lidar_timestamp - request.frame_timestamp);
            if (!lidar_query.used_bbox_match) {
              log << " lidar_fallback=nearest_point";
            }

            std::string plan_message;
            std::vector<core::Vector3d> planned_path_world;
            core::Vector3d goal_world{};
            if (plan_path_to_stop_sign(
                    g_lidar_data,
                    lidar_query,
                    &planned_path_world,
                    &goal_world,
                    &plan_message)) {
              active_goal_world = goal_world;
              active_path_world = planned_path_world;
              wheel_pose = core::PoseSE2d{};
              wheel_odom_origin_initialized = false;
              last_odom_seq = std::numeric_limits<int32_t>::min();
              last_follow_log_timestamp = -1.0;
              path_follower.clear_path();
              path_follower.set_path(active_path_world);
              motors.reset_twist_controller();
              write_stop_command();
              state = DemoState::kFollowingPath;
              log << " plan_goal=(" << goal_world.x << "," << goal_world.y
                  << ") path_waypoints=" << active_path_world.size();
              if (!plan_message.empty()) {
                log << " plan=" << plan_message;
              }
            } else {
              log << " plan_failed=" << plan_message;
            }
          } else {
            log << " lidar=unavailable";
          }
        } else {
          log << " bbox=invalid";
        }
        log << " frame_t=" << request.frame_timestamp;
        wasm_log_line(log.str());
        last_log_timestamp = request.frame_timestamp;
      }
      stop_latched = true;
    } else if (stop_latched && request.frame_timestamp - last_log_timestamp >= 1.0) {
      std::ostringstream log;
      log << "[stop_sign] clear frame_t=" << request.frame_timestamp;
      wasm_log_line(log.str());
      last_log_timestamp = request.frame_timestamp;
      stop_latched = false;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(kLoopSleepMs));
  }

  const int32_t close_status = ml::close_model(model_id);
  if (close_status != ml::kSuccess) {
    std::ostringstream log;
    log << "[stop_sign] close model status=" << ml::status_name(close_status)
        << " code=" << close_status;
    wasm_log_line(log.str());
  }
  return 0;
}
