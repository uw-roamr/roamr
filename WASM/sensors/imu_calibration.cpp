#include "sensors/calibration.h"
#include <iostream>

namespace sensors::calibration{

    void IMUCalibration::update(){
        IMUData& curr = curr_slot();
        if (curr.timestamp <= last_imu_timestamp) return;
        last_imu_timestamp = curr.timestamp;
        const double acc = core::norm(curr.acc_x, curr.acc_y, curr.acc_z);
        const double gyro = core::norm(curr.gyro_x, curr.gyro_y, curr.gyro_z);
        if (acc < kIMU_acc_still_low || acc > kIMU_acc_still_high || gyro > kIMU_gyro_still_thresh_mag){
            still_timestamps_ = 0;
            reset_sums();
            return;
        }
        still_timestamps_++;
        increment_sums(curr);
    }

    void IMUCalibration::reset_sums() noexcept{
        sum_gyro[0] = 0.0;
        sum_gyro[1] = 0.0;
        sum_gyro[2] = 0.0;
        sum_acc[0] = 0.0;
        sum_acc[1] = 0.0;
        sum_acc[2] = 0.0;
    }

    void IMUCalibration::increment_sums(IMUData& imu_data) noexcept{
        sum_gyro[0] += imu_data.gyro_x;
        sum_gyro[1] += imu_data.gyro_y;
        sum_gyro[2] += imu_data.gyro_z;
        sum_acc[0] += imu_data.acc_x;
        sum_acc[1] += imu_data.acc_y;
        sum_acc[2] += imu_data.acc_z;
    }

    void IMUCalibration::recalibrate(){
        if (still_timestamps_ < kIMU_calib_samples) return;

        for(size_t i = 0; i < 3; ++i){
            gyro_bias[i] = sum_gyro[i] / still_timestamps_;
            const double acc_mean = sum_acc[i] / still_timestamps_;
            acc_bias[i] = acc_mean - gravity[i];
        }

        std::cout << "calibrated IMU" << std::endl;
    }

    void IMUCalibration::init_biases(){
        still_timestamps_ = 0;
        calibrated = false;
        last_imu_timestamp = -1.0;
        reset_sums();

        while(not calibrated){
            do {
                IMUData& imu_data = new_write_slot();
                do {
                read_imu(&imu_data);
                } while (imu_data.timestamp <= last_imu_timestamp);

                update();
            } while (still_timestamps_ < kIMU_calib_samples);

            const double acc_mean_x = sum_acc[0]/ still_timestamps_;
            const double acc_mean_y = sum_acc[1]/ still_timestamps_;
            const double acc_mean_z = sum_acc[2]/ still_timestamps_;

            const double acc_mean = core::norm(acc_mean_x, acc_mean_y, acc_mean_z);
            if (acc_mean < acc_epsilon) continue;

            // initialize gravity (z down)
            gravity[0] = expected_gravity * acc_mean_x / acc_mean; 
            gravity[1] = expected_gravity * acc_mean_y / acc_mean;
            gravity[2] = expected_gravity * acc_mean_z / acc_mean;
            std::cout << "initialized g: " << gravity[0] << ", " << gravity[1] << ", " << gravity[2] << std::endl;

            recalibrate();
            calibrated = true;
        }
        
    }


};
