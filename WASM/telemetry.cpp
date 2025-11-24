#include "telemetry.h"
#include "lidar_camera.h"
#include <mutex>

// log sensors without significant delays in processing
void log_sensors(std::mutex& m_imu, const IMUData& imu_data, std::mutex& m_lc, const LidarCameraData& lc_data){
  std::cout << std::fixed << std::setprecision(5);
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(log_interval_ms));

    IMUData imu_copy;
    {
      std::lock_guard<std::mutex> lk(m_imu);
      imu_copy = imu_data;
    }

    // very expensive to copy everything! 
    // LidarCameraData lc_copy;
    double lc_timestamp;
    size_t img_w, img_h;
    {
      std::lock_guard<std::mutex> lk(m_lc);
      lc_timestamp = lc_data.timestamp;
      img_h = lc_data.image_height;
      img_w = lc_data.image_width;
    }

        std::cout << "T:" << imu_copy.acc_timestamp << " acc:" << imu_copy.acc_x << "," << imu_copy.acc_y << "," << imu_copy.acc_z << std::endl
                    << "T:" << imu_copy.gyro_timestamp << " gyro:" << imu_copy.gyro_x << "," << imu_copy.gyro_y << "," << imu_copy.gyro_z <<
                    std::endl;
        // not sure what the best way to log lidar_camera_data is
        std::cout << "T:" << lc_timestamp << " lidar camera: " << img_h << ", " << img_w << std::endl;
  }
};
