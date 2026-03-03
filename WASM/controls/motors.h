#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <thread>
#include <chrono>

#include "core/wasm_utils.h"
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
    constexpr double kMaxAngularSpeedRadPerSec = 3.14159265358979323846;

    struct WheelSpeedSetpoint {
        double left_mps;
        double right_mps;
    };

    struct WheelSpeedControllerConfig {
        // Conservative defaults to reduce jerk and oscillation.
        double kff_percent_per_mps = 60.0;
        double kp_percent_per_mps = 30.0;
        double ki_percent_per_mps_s = 10.0;
        double integral_limit_percent = 10.0;
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

            const double left_error = desired.left_mps - measured.left;
            const double right_error = desired.right_mps - measured.right;

            if (measured.dt_seconds > 0.0) {
                left_i_term_percent_ = clamp_percent_double(
                    left_i_term_percent_ + (cfg_.ki_percent_per_mps_s * left_error * measured.dt_seconds),
                    cfg_.integral_limit_percent);
                right_i_term_percent_ = clamp_percent_double(
                    right_i_term_percent_ + (cfg_.ki_percent_per_mps_s * right_error * measured.dt_seconds),
                    cfg_.integral_limit_percent);
            }

            const double left_pct = (cfg_.kff_percent_per_mps * desired.left_mps) +
                                    (cfg_.kp_percent_per_mps * left_error) +
                                    left_i_term_percent_;
            const double right_pct = (cfg_.kff_percent_per_mps * desired.right_mps) +
                                     (cfg_.kp_percent_per_mps * right_error) +
                                     right_i_term_percent_;

            return MotorCommand{
                clamp_percent(round_to_i32(left_pct)),
                clamp_percent(round_to_i32(right_pct)),
                clamp_nonnegative(hold_ms)};
        }

    private:
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
        explicit MotorController(const WheelSpeedControllerConfig& wheel_speed_cfg = {})
            : wheel_speed_controller_(wheel_speed_cfg) {}

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
            const WheelSpeedSetpoint desired = wheel_speed_setpoint_from_twist(cmd);
            const sensors::WheelSpeedMetersPerSec measured = sensors::wheel_speed_from_odometry(odom);
            const MotorCommand motor_cmd =
                wheel_speed_controller_.compute(desired, measured, cmd.hold_ms);
            write_motors(&motor_cmd);
        }

        // Blocking twist helper: repeatedly closes loop on wheel odometry for duration_ms.
        void drive_twist_for(
            double v_mps,
            double omega_rad_s,
            int duration_ms,
            bool stop_after = true,
            int hold_ms = 120) {
            sensors::WheelOdometryData odom = {};
            const auto deadline =
                std::chrono::steady_clock::now() + std::chrono::milliseconds(clamp_nonnegative(duration_ms));
            const int safe_hold_ms = clamp_nonnegative(hold_ms);
            while (std::chrono::steady_clock::now() < deadline) {
                read_wheel_odometry(&odom);
                if (odom.seq >= 0 && odom.timestamp > 0.0 && odom.sample_period_ms > 0) {
                    drive_twist(v_mps, omega_rad_s, odom, safe_hold_ms);
                    const int sleep_ms = std::clamp(odom.sample_period_ms, 1, 50);
                    std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
                } else {
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                }
            }
            if (stop_after) {
                stop();
            }
        }

        void reset_twist_controller() { wheel_speed_controller_.reset(); }

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
        static int32_t clamp_percent(int value) {
            return std::clamp<int32_t>(value, -100, 100);
        }

        static int32_t clamp_nonnegative(int value) {
            return value < 0 ? 0 : static_cast<int32_t>(value);
        }

        WheelSpeedPercentController wheel_speed_controller_;
    };

    void drive_forward_demo() {
        MotorController motors;

        // Ramp from reverse to forward with a dwell at each step.
        // for (int i = -2; i <= 3; i++){
        //     const int pct = i * 10;
        //     motors.drive_for(-pct, pct, 3000, true);
        // }

        // motors.drive_twist_for(0.15, 0.0, 2000, true);

        motors.stop();
    }

    void drive_twist_demo() {
        MotorController motors;
        motors.drive_twist_for(0.15, 0.0, 2000, false);
        motors.reset_twist_controller();
        motors.drive_twist_for(0.0, -0.5 * kMaxAngularSpeedRadPerSec, 4000, true);
        motors.stop();
    }
}; //namespace controls
