#pragma once
#include "core/pose/coordinate_frames.h"
#include "core/math_utils.h"
#include "core/ring_buffer.h"
#include "sensors/imu.h"


namespace sensors::calibration{
    constexpr double expected_gravity = 9.80665;
    constexpr double acc_still = 0.6; // m/s^2
    constexpr double acc_epsilon = 1e-6;
    constexpr double kIMU_acc_still_low = expected_gravity - acc_still;
    constexpr double kIMU_acc_still_high = expected_gravity + acc_still;

    constexpr double kIMU_recalibrate_interval_s = 1.0;

    constexpr double kIMU_gyro_still_thresh_mag = 0.05; // rad/s

    constexpr int kIMU_calib_samples = 100;

    using IMUHistoryBuffer = core::RingBuffer<IMUData, kIMU_calib_samples>;


    class IMUCalibration {
    public:
        IMUCalibration() = delete;
        explicit IMUCalibration(IMUHistoryBuffer& history) noexcept
            : history_(history) {}

        bool calibrated = false;
        double window_start = -1.0;
        int sample_count = 0;
        core::Vector3d sum_acc{};
        core::Vector3d sum_gyro{};
        core::Vector3d gyro_bias{};
        core::Vector3d acc_bias{};
        core::Vector3d gravity{};
        double last_calibrated = 0.0;
        double last_imu_timestamp = -1.0;

        IMUData& curr_slot() noexcept{
            return history_.back();
        }

        IMUData& new_write_slot() noexcept{
            return history_.push_slot();
        }
        void update();
        void recalibrate();
        void init_biases();

    private:
        void increment_sums(IMUData& imu_data) noexcept;
        void reset_sums() noexcept;
        int still_timestamps_ = 0;
        IMUHistoryBuffer& history_;

    };




} // namespace
