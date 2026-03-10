#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "controls/motors.h"
#include "core/math_utils.h"

namespace controls {

struct Pose2D {
  double x = 0.0;
  double y = 0.0;
  double yaw = 0.0;
};

struct PIDGains {
  double kp = 0.0;
  double ki = 0.0;
  double kd = 0.0;
  double integral_limit = 0.0;
};

struct PathFollowerConfig {
  PIDGains distance_pid{1.8, 0.0, 0.12, 0.6};
  PIDGains heading_pid{3.6, 0.0, 0.22, 1.5};

  double lookahead_m = 0.14;
  double waypoint_reached_m = 0.08;
  double goal_tolerance_m = 0.1;
  double goal_heading_tolerance_rad = 0.22;

  double max_linear_speed_mps = kMaxLinearSpeedMps;
  double max_angular_speed_rad_s = kMaxAngularSpeedRadPerSec;
  double max_linear_accel_mps2 = 0.8;
  double max_angular_accel_rad_s2 = 6.0;

  bool allow_reverse = false;
  bool slow_down_near_goal = true;
};

struct PathFollowerStatus {
  TwistCommand command{0.0, 0.0, 0};
  bool has_path = false;
  bool goal_reached = false;
  size_t target_index = 0;
  double distance_error_m = 0.0;
  double heading_error_rad = 0.0;
};

class PathFollower {
 public:
  explicit PathFollower(const PathFollowerConfig& cfg = {}) : cfg_(cfg) {}

  void set_config(const PathFollowerConfig& cfg) {
    cfg_ = cfg;
    reset_controller_state();
  }

  const PathFollowerConfig& config() const { return cfg_; }

  void set_path(const std::vector<core::Vector3d>& path_world) {
    path_ = path_world;
    target_index_ = 0;
    reset_controller_state();
  }

  void clear_path() {
    path_.clear();
    target_index_ = 0;
    reset_controller_state();
  }

  bool has_path() const { return !path_.empty(); }
  size_t target_index() const { return target_index_; }

  PathFollowerStatus update(const Pose2D& pose, double dt_seconds, int hold_ms = 100) {
    PathFollowerStatus status;
    status.has_path = !path_.empty();
    status.command.hold_ms = hold_ms < 0 ? 0 : hold_ms;

    if (path_.empty()) {
      return status;
    }

    const double dt = std::max(1e-3, dt_seconds);
    advance_waypoint_if_reached(pose);

    const core::Vector3d& goal = path_.back();
    const double goal_dist = euclidean_distance(pose.x, pose.y, goal.x, goal.y);
    const double goal_heading_error =
        path_.size() < 2 ? 0.0 : normalize_angle(final_path_heading() - pose.yaw);

    if (goal_dist <= cfg_.goal_tolerance_m) {
      reset_controller_state();
      status.goal_reached = true;
      status.target_index = path_.size() - 1;
      status.distance_error_m = goal_dist;
      status.heading_error_rad = goal_heading_error;
      return status;
    }

    const size_t lookahead_index = select_lookahead_index(pose);
    target_index_ = lookahead_index;
    const core::Vector3d& target = path_[lookahead_index];

    const double dx = target.x - pose.x;
    const double dy = target.y - pose.y;
    const double dist_error = std::hypot(dx, dy);
    const double desired_heading = std::atan2(dy, dx);
    const double heading_error = normalize_angle(desired_heading - pose.yaw);

    double linear_cmd = pid_update(
        dist_error,
        dt,
        cfg_.distance_pid,
        &distance_integral_,
        &prev_distance_error_,
        &has_prev_distance_error_);
    double angular_cmd = pid_update(
        heading_error,
        dt,
        cfg_.heading_pid,
        &heading_integral_,
        &prev_heading_error_,
        &has_prev_heading_error_);

    // Gate forward speed while pointing away from the target to avoid overshoot.
    const double heading_gate =
        std::clamp(std::cos(std::abs(heading_error)), 0.0, 1.0);
    linear_cmd *= heading_gate;

    if (cfg_.slow_down_near_goal) {
      const double slowdown_radius = std::max(cfg_.lookahead_m, 1e-3);
      const double slowdown = std::clamp(goal_dist / slowdown_radius, 0.2, 1.0);
      linear_cmd *= slowdown;
    }

    if (!cfg_.allow_reverse) {
      linear_cmd = std::max(0.0, linear_cmd);
    }

    linear_cmd = std::clamp(
        linear_cmd, -cfg_.max_linear_speed_mps, cfg_.max_linear_speed_mps);
    angular_cmd = std::clamp(
        angular_cmd, -cfg_.max_angular_speed_rad_s, cfg_.max_angular_speed_rad_s);

    linear_cmd = apply_slew_rate_limit(
        linear_cmd, last_linear_cmd_, cfg_.max_linear_accel_mps2, dt);
    angular_cmd = apply_slew_rate_limit(
        angular_cmd, last_angular_cmd_, cfg_.max_angular_accel_rad_s2, dt);

    last_linear_cmd_ = linear_cmd;
    last_angular_cmd_ = angular_cmd;

    status.command.v_mps = linear_cmd;
    status.command.omega_rad_s = angular_cmd;
    status.target_index = target_index_;
    status.distance_error_m = dist_error;
    status.heading_error_rad = heading_error;
    return status;
  }

 private:
  static double euclidean_distance(
      double x0, double y0, double x1, double y1) {
    return std::hypot(x1 - x0, y1 - y0);
  }

  static double normalize_angle(double angle) {
    while (angle > core::pi) {
      angle -= 2.0 * core::pi;
    }
    while (angle < -core::pi) {
      angle += 2.0 * core::pi;
    }
    return angle;
  }

  static double apply_slew_rate_limit(
      double desired,
      double previous,
      double max_rate_per_sec,
      double dt_seconds) {
    if (max_rate_per_sec <= 0.0 || dt_seconds <= 0.0) {
      return desired;
    }
    const double delta_limit = max_rate_per_sec * dt_seconds;
    const double delta = desired - previous;
    if (delta > delta_limit) {
      return previous + delta_limit;
    }
    if (delta < -delta_limit) {
      return previous - delta_limit;
    }
    return desired;
  }

  static double pid_update(
      double error,
      double dt_seconds,
      const PIDGains& gains,
      double* integral_state,
      double* prev_error_state,
      bool* has_prev_error_state) {
    if (!integral_state || !prev_error_state || !has_prev_error_state) {
      return 0.0;
    }

    *integral_state += error * dt_seconds;
    if (gains.integral_limit > 0.0) {
      *integral_state = std::clamp(
          *integral_state, -gains.integral_limit, gains.integral_limit);
    }

    double derivative = 0.0;
    if (*has_prev_error_state) {
      derivative = (error - *prev_error_state) / dt_seconds;
    } else {
      *has_prev_error_state = true;
    }
    *prev_error_state = error;

    return gains.kp * error +
           gains.ki * (*integral_state) +
           gains.kd * derivative;
  }

  void reset_controller_state() {
    distance_integral_ = 0.0;
    heading_integral_ = 0.0;
    prev_distance_error_ = 0.0;
    prev_heading_error_ = 0.0;
    has_prev_distance_error_ = false;
    has_prev_heading_error_ = false;
    last_linear_cmd_ = 0.0;
    last_angular_cmd_ = 0.0;
  }

  void advance_waypoint_if_reached(const Pose2D& pose) {
    while (target_index_ + 1 < path_.size()) {
      const core::Vector3d& waypoint = path_[target_index_];
      const double d = euclidean_distance(pose.x, pose.y, waypoint.x, waypoint.y);
      if (d > cfg_.waypoint_reached_m) {
        break;
      }
      ++target_index_;
    }
  }

  size_t select_lookahead_index(const Pose2D& pose) const {
    size_t idx = target_index_;
    while (idx + 1 < path_.size()) {
      const core::Vector3d& p = path_[idx];
      const double d = euclidean_distance(pose.x, pose.y, p.x, p.y);
      if (d >= cfg_.lookahead_m) {
        break;
      }
      ++idx;
    }
    return idx;
  }

  double final_path_heading() const {
    if (path_.size() < 2) {
      return 0.0;
    }
    const core::Vector3d& a = path_[path_.size() - 2];
    const core::Vector3d& b = path_[path_.size() - 1];
    return std::atan2(b.y - a.y, b.x - a.x);
  }

  PathFollowerConfig cfg_;
  std::vector<core::Vector3d> path_;
  size_t target_index_ = 0;

  double distance_integral_ = 0.0;
  double heading_integral_ = 0.0;
  double prev_distance_error_ = 0.0;
  double prev_heading_error_ = 0.0;
  bool has_prev_distance_error_ = false;
  bool has_prev_heading_error_ = false;

  double last_linear_cmd_ = 0.0;
  double last_angular_cmd_ = 0.0;
};

}  // namespace controls
