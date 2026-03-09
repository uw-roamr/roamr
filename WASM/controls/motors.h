#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <thread>
#include <chrono>

#include "core/wasm_utils.h"
#include "core/math_utils.h"
#include "sensors/wheel_odometry.h"

namespace controls{
    // Desired motor output in percentage of full scale (-100 to 100)
    // hold_ms lets the host decide how long to keep this command alive.
    struct MotorCommand {
        int32_t left_percent;   // left wheel, -100..100
        int32_t right_percent;  // right wheel, -100..100
        int32_t hold_ms;        // command validity in milliseconds
    };

    WASM_IMPORT("host", "write_motors") void write_motors(const MotorCommand *cmd);

    struct TwistCommand {
        double v_mps;           // body-frame linear velocity (m/s)
        double omega_rad_s;     // body-frame yaw rate (rad/s)
        int32_t hold_ms;        // command validity in milliseconds
    };

    constexpr double kMaxLinearSpeedMps = 0.3;
    constexpr double kMaxAngularSpeedRadPerSec = core::pi;

    struct WheelSpeedSetpoint {
        double left_mps;
        double right_mps;
    };

    struct WheelCommandBandConfig {
        // Keep nonzero wheel commands in this range.
        double min_moving_percent = 10.0;
        double max_moving_percent = 18.0;
        // If desired wheel speed is below this threshold, command a full stop.
        double stop_speed_threshold_mps = 0.01;
        // PI correction is intentionally small; feedforward does most of the work.
        double max_trim_percent = 3.0;
        // Maximum wheel speed expected while staying inside moving percent band.
        double max_wheel_speed_for_band_mps = 0.16;
    };

    struct TwistCommandCalibrationConfig {
        // Scales (v, omega) before converting to wheel speed setpoints.
        // Defaults tuned for uninterrupted odom updates from a single consumer.
        double linear_scale = 0.25;
        double angular_scale = 1.1;
    };

    struct WheelSpeedControllerConfig {
        // PI trim around a feedforward operating band.
        double kp_percent_per_mps = 20.0;
        double ki_percent_per_mps_s = 3.0;
        double integral_limit_percent = 6.0;
        WheelCommandBandConfig band = {};
        TwistCommandCalibrationConfig twist_calibration = {};
    };

    struct TurnInPlaceConfig {
        // Outer-loop yaw controller that commands angular velocity from yaw error.
        double kp_omega_per_rad = 2.0;
        double max_omega_rad_s = 0.9 * kMaxAngularSpeedRadPerSec;
        double min_omega_rad_s = 0.2;
        double yaw_tolerance_rad = 3.0 * core::pi / 180.0;
    };

    inline TwistCommand clamp_twist_command(const TwistCommand& cmd) {
        return TwistCommand{
            std::clamp(cmd.v_mps, -kMaxLinearSpeedMps, kMaxLinearSpeedMps),
            std::clamp(cmd.omega_rad_s, -kMaxAngularSpeedRadPerSec, kMaxAngularSpeedRadPerSec),
            cmd.hold_ms};
    }

    inline WheelSpeedSetpoint wheel_speed_setpoint_from_twist(const TwistCommand& cmd) {
        const TwistCommand clamped = clamp_twist_command(cmd);
        const double half_wheel_base = 0.5 * sensors::kWheelBaseMeters;
        return WheelSpeedSetpoint{
            clamped.v_mps - (clamped.omega_rad_s * half_wheel_base),
            clamped.v_mps + (clamped.omega_rad_s * half_wheel_base)};
    }

    inline TwistCommand apply_twist_calibration(
        const TwistCommand& cmd,
        const TwistCommandCalibrationConfig& cfg) {
        const double linear_scale = std::max(0.0, cfg.linear_scale);
        const double angular_scale = std::max(0.0, cfg.angular_scale);
        return TwistCommand{
            cmd.v_mps * linear_scale,
            cmd.omega_rad_s * angular_scale,
            cmd.hold_ms};
    }

    inline WheelSpeedSetpoint clamp_wheel_speed_setpoint_to_band(
        const WheelSpeedSetpoint& desired,
        double max_abs_wheel_speed_mps) {
        const double max_abs_speed = std::max(0.0, max_abs_wheel_speed_mps);
        if (max_abs_speed <= 0.0) {
            return WheelSpeedSetpoint{0.0, 0.0};
        }
        const double peak = std::max(std::abs(desired.left_mps), std::abs(desired.right_mps));
        if (peak <= max_abs_speed || peak <= 1e-9) {
            return desired;
        }
        const double scale = max_abs_speed / peak;
        return WheelSpeedSetpoint{desired.left_mps * scale, desired.right_mps * scale};
    }

    class WheelSpeedPercentController {
    public:
        explicit WheelSpeedPercentController(const WheelSpeedControllerConfig& cfg = {})
            : cfg_(cfg) {}

        void reset() {
            left_i_term_percent_ = 0.0;
            right_i_term_percent_ = 0.0;
        }

        void set_config(const WheelSpeedControllerConfig& cfg) {
            cfg_ = cfg;
            reset();
        }

        const WheelSpeedControllerConfig& config() const { return cfg_; }

        MotorCommand compute(
            const WheelSpeedSetpoint& desired,
            const sensors::WheelSpeedMetersPerSec& measured,
            int hold_ms) {
            const double left_pct = compute_wheel_percent(
                desired.left_mps,
                measured.left,
                measured.dt_seconds,
                &left_i_term_percent_);
            const double right_pct = compute_wheel_percent(
                desired.right_mps,
                measured.right,
                measured.dt_seconds,
                &right_i_term_percent_);

            return MotorCommand{
                clamp_percent(round_to_i32(left_pct)),
                clamp_percent(round_to_i32(right_pct)),
                clamp_nonnegative(hold_ms)};
        }

    private:
        double compute_wheel_percent(
            double desired_mps,
            double measured_mps,
            double dt_seconds,
            double* i_term_percent) const {
            if (!i_term_percent) {
                return 0.0;
            }

            const double desired_abs = std::abs(desired_mps);
            const double stop_threshold = std::max(0.0, cfg_.band.stop_speed_threshold_mps);
            if (desired_abs <= stop_threshold) {
                *i_term_percent = 0.0;
                return 0.0;
            }

            const double error = desired_mps - measured_mps;
            const double i_term_candidate = integrate_i_term(*i_term_percent, error, dt_seconds);
            const double p_term = cfg_.kp_percent_per_mps * error;
            const double trim_limit = std::max(0.0, cfg_.band.max_trim_percent);
            const double trim_unclamped = p_term + i_term_candidate;
            const double trim = clamp_percent_double(trim_unclamped, trim_limit);

            const double ff_abs = feedforward_percent_for_speed(desired_abs);
            const double raw_cmd = std::copysign(ff_abs, desired_mps) + trim;

            const double min_moving = std::max(0.0, cfg_.band.min_moving_percent);
            const double max_moving = std::max(min_moving, cfg_.band.max_moving_percent);
            const double cmd_abs = std::clamp(std::abs(raw_cmd), min_moving, max_moving);
            const double cmd = std::copysign(cmd_abs, desired_mps);

            const bool trim_saturated = std::abs(trim_unclamped - trim) > 1e-9;
            const bool output_saturated = std::abs(raw_cmd - cmd) > 1e-9;
            const bool correction_reduces_saturation =
                (cmd > 0.0 && error < 0.0) || (cmd < 0.0 && error > 0.0);

            if (dt_seconds > 0.0 &&
                ((!trim_saturated && !output_saturated) || correction_reduces_saturation)) {
                *i_term_percent = i_term_candidate;
            }

            return cmd;
        }

        double integrate_i_term(double i_term_percent, double error, double dt_seconds) const {
            if (dt_seconds <= 0.0) {
                return i_term_percent;
            }
            return clamp_percent_double(
                i_term_percent + (cfg_.ki_percent_per_mps_s * error * dt_seconds),
                cfg_.integral_limit_percent);
        }

        double feedforward_percent_for_speed(double desired_abs_mps) const {
            const double min_moving = std::max(0.0, cfg_.band.min_moving_percent);
            const double max_moving = std::max(min_moving, cfg_.band.max_moving_percent);
            const double max_speed = std::max(1e-6, cfg_.band.max_wheel_speed_for_band_mps);
            const double speed_norm = std::clamp(desired_abs_mps / max_speed, 0.0, 1.0);
            return min_moving + (speed_norm * (max_moving - min_moving));
        }

        static int32_t round_to_i32(double value) {
            return static_cast<int32_t>(std::lround(value));
        }

        static double clamp_percent_double(double value, double limit) {
            const double safe_limit = std::max(0.0, limit);
            return std::clamp(value, -safe_limit, safe_limit);
        }

        static int32_t clamp_percent(int32_t value) {
            return std::clamp<int32_t>(value, -100, 100);
        }

        static int32_t clamp_nonnegative(int value) {
            return value < 0 ? 0 : static_cast<int32_t>(value);
        }

        WheelSpeedControllerConfig cfg_;
        double left_i_term_percent_ = 0.0;
        double right_i_term_percent_ = 0.0;
    };

    // Small helper to make the C++ callsite pleasant and safe.
    class MotorController {
    public:
        using OdomSnapshotReader = bool (*)(sensors::WheelOdometryData*);

        explicit MotorController(
            const WheelSpeedControllerConfig& wheel_speed_cfg = {},
            OdomSnapshotReader odom_reader = nullptr)
            : wheel_speed_controller_(wheel_speed_cfg),
              odom_reader_(odom_reader) {}

        void set_odom_reader(OdomSnapshotReader odom_reader) {
            odom_reader_ = odom_reader;
        }

        // Sends a differential drive command. Percent values are clamped to [-100, 100].
        void drive_percent(int left_pct, int right_pct, int hold_ms = 100) const {
            MotorCommand cmd{
                clamp_percent(left_pct),
                clamp_percent(right_pct),
                clamp_nonnegative(hold_ms)};
            write_motors(&cmd);
        }

        // Closed-loop twist command using wheel odometry feedback.
        // The caller should invoke this on each new odometry sample.
        void drive_twist(
            double v_mps,
            double omega_rad_s,
            const sensors::WheelOdometryData& odom,
            int hold_ms = 100) {
            drive_twist(TwistCommand{v_mps, omega_rad_s, clamp_nonnegative(hold_ms)}, odom);
        }

        void drive_twist(const TwistCommand& cmd, const sensors::WheelOdometryData& odom) {
            const TwistCommand calibrated_cmd =
                apply_twist_calibration(cmd, wheel_speed_controller_.config().twist_calibration);
            const WheelSpeedSetpoint desired_raw = wheel_speed_setpoint_from_twist(calibrated_cmd);
            const WheelSpeedSetpoint desired = clamp_wheel_speed_setpoint_to_band(
                desired_raw,
                wheel_speed_controller_.config().band.max_wheel_speed_for_band_mps);
            const sensors::WheelSpeedMetersPerSec measured = sensors::wheel_speed_from_odometry(odom);
            const MotorCommand motor_cmd =
                wheel_speed_controller_.compute(desired, measured, cmd.hold_ms);
            last_twist_motor_cmd_ = motor_cmd;
            has_last_twist_motor_cmd_ = true;
            write_motors(&motor_cmd);
        }

        // One step of an outer-loop "turn to yaw" controller.
        // Uses unwrapped yaw values (do not angle-wrap in caller).
        // Returns true when the target is reached within tolerance.
        bool drive_turn_to_yaw(
            double current_yaw_rad,
            double target_yaw_rad,
            const sensors::WheelOdometryData& odom,
            const TurnInPlaceConfig& cfg = {},
            int hold_ms = 120) {
            const double yaw_error = target_yaw_rad - current_yaw_rad;
            const double yaw_tolerance = std::max(1e-6, cfg.yaw_tolerance_rad);
            if (std::abs(yaw_error) <= yaw_tolerance) {
                stop();
                return true;
            }

            const double kp = std::max(0.0, cfg.kp_omega_per_rad);
            const double max_omega =
                std::clamp(std::abs(cfg.max_omega_rad_s), 0.0, kMaxAngularSpeedRadPerSec);
            if (max_omega <= 0.0) {
                stop();
                return false;
            }
            const double min_omega = std::clamp(std::abs(cfg.min_omega_rad_s), 0.0, max_omega);

            double omega_cmd = kp * yaw_error;
            omega_cmd = std::clamp(omega_cmd, -max_omega, max_omega);
            if (std::abs(omega_cmd) < min_omega) {
                omega_cmd = std::copysign(min_omega, yaw_error);
            }

            drive_twist(0.0, omega_cmd, odom, hold_ms);
            return false;
        }

        // Blocking twist helper: repeatedly closes loop on wheel odometry for duration_ms.
        // If an odom reader is configured, this does not pop the host odom queue directly.
        void drive_twist_for(
            double v_mps,
            double omega_rad_s,
            int duration_ms,
            bool stop_after = true,
            int hold_ms = 0) {
            sensors::WheelOdometryData odom = {};
            constexpr int kControlTickMs = 20;
            constexpr int kMinSafeHoldMs = 250;
            const auto deadline =
                std::chrono::steady_clock::now() + std::chrono::milliseconds(clamp_nonnegative(duration_ms));
            const int requested_hold_ms = clamp_nonnegative(hold_ms);
            // hold_ms == 0 disables host-side auto-stop; this avoids watchdog stutter.
            const int safe_hold_ms =
                (requested_hold_ms == 0) ? 0 : std::max(kMinSafeHoldMs, requested_hold_ms);
            auto next_tick = std::chrono::steady_clock::now();
            int32_t last_applied_seq = std::numeric_limits<int32_t>::min();
            while (std::chrono::steady_clock::now() < deadline) {
                next_tick += std::chrono::milliseconds(kControlTickMs);
                if (read_control_odometry(odom) && odom.seq != last_applied_seq) {
                    drive_twist(v_mps, omega_rad_s, odom, safe_hold_ms);
                    last_applied_seq = odom.seq;
                } else {
                    refresh_last_twist_command(safe_hold_ms);
                }
                std::this_thread::sleep_until(std::min(next_tick, deadline));
            }
            if (stop_after) {
                stop();
            }
        }

        void reset_twist_controller() {
            wheel_speed_controller_.reset();
            has_last_twist_motor_cmd_ = false;
        }

        WheelSpeedPercentController& twist_controller() { return wheel_speed_controller_; }
        const WheelSpeedPercentController& twist_controller() const { return wheel_speed_controller_; }

        // Blocking helper: send a command, wait for duration_ms, and optionally stop.
        void drive_for(int left_pct, int right_pct, int duration_ms, bool stop_after = true) const {
            drive_percent(left_pct, right_pct, duration_ms);
            std::this_thread::sleep_for(std::chrono::milliseconds(clamp_nonnegative(duration_ms)));
            if (stop_after) {
                drive_percent(0, 0, 0);
            }
        }

        // Convenience stop shortcut.
        void stop() const { drive_percent(0, 0, 0); }

    private:
        bool read_control_odometry(sensors::WheelOdometryData& odom) const {

            if (odom_reader_) {
                return odom_reader_(&odom);
            }
            read_wheel_odometry(&odom);
            return odom.seq >= 0 && odom.timestamp > 0.0 && odom.sample_period_ms > 0;
        }

        void refresh_last_twist_command(int hold_ms) {
            if (!has_last_twist_motor_cmd_) {
                return;
            }
            MotorCommand cmd = last_twist_motor_cmd_;
            cmd.hold_ms = clamp_nonnegative(hold_ms);
            write_motors(&cmd);
        }

        static int32_t clamp_percent(int value) {
            return std::clamp<int32_t>(value, -100, 100);
        }

        static int32_t clamp_nonnegative(int value) {
            return value < 0 ? 0 : static_cast<int32_t>(value);
        }

        WheelSpeedPercentController wheel_speed_controller_;
        OdomSnapshotReader odom_reader_;
        MotorCommand last_twist_motor_cmd_{0, 0, 0};
        bool has_last_twist_motor_cmd_ = false;
    };

    void drive_forward_demo() {
        MotorController motors;

        // Ramp from reverse to forward with a dwell at each step.
        // for (int i = -2; i <= 3; i++){
        //     const int pct = i * 10;
        //     motors.drive_for(-pct, pct, 3000, true);
        // }

        motors.drive_for(15, 15, 2000, true);
        motors.drive_for(-15, 15, 2000, true);
        // motors.drive_twist_for(0.15, 0.0, 2000, true);

        motors.stop();
    }

    void drive_twist_demo(MotorController& motors) {
        motors.drive_twist_for(0.1, 0.0, 2000, false);
        motors.reset_twist_controller();
        motors.drive_twist_for(0.0, 0.5 * core::pi, 4000, true);
        motors.stop();
    }
}; //namespace controls
