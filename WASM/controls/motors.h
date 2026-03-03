#pragma once

#include <algorithm>
#include <cstdint>
#include <thread>
#include <chrono>

#include "core/wasm_utils.h"

namespace controls{
    // Desired motor output in percentage of full scale (-100 to 100)
    // hold_ms lets the host decide how long to keep this command alive.
    struct MotorCommand {
        int32_t left_percent;   // left wheel, -100..100
        int32_t right_percent;  // right wheel, -100..100
        int32_t hold_ms;        // command validity in milliseconds
    };

    WASM_IMPORT("host", "write_motors") void write_motors(const MotorCommand *cmd);

    // Small helper to make the C++ callsite pleasant and safe.
    class MotorController {
    public:
        // Sends a differential drive command. Percent values are clamped to [-100, 100].
        void drive_percent(int left_pct, int right_pct, int hold_ms = 100) const {
            MotorCommand cmd{
                clamp_percent(left_pct),
                clamp_percent(right_pct),
                clamp_nonnegative(hold_ms)};
            write_motors(&cmd);
        }

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
    };

    void drive_forward_demo() {
        MotorController motors;

        // Ramp from reverse to forward with a dwell at each step.
        for (int i = -2; i <= 3; i++){
            const int pct = i * 10;
            motors.drive_for(-pct, pct, 3000, true);
        }
        motors.stop();
    }
}; //namespace controls
