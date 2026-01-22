#include "telemetry.h"
#include "lidar_camera.h"
#include <mutex>

void log_config(const CameraConfig& cam_config){
  std::cout << "Sensor config" << std::endl;
  std::cout << "T: " << cam_config.timestamp << ", height: " << cam_config.image_height << ", width: " << cam_config.image_width << ", channels: " << cam_config.image_channels << std::endl;
}

// log sensors without significant delays in processing
void log_sensors(std::mutex& m_imu, const IMUData& imu_data, std::mutex& m_lc, const LidarCameraData& lc_data){
  std::cout << std::fixed << std::setprecision(5);
  double last_lc_timestamp = -1.0;
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(log_interval_ms));

    IMUData imu_copy;
    {
      std::lock_guard<std::mutex> lk(m_imu);
      imu_copy = imu_data;
    }

    // very expensive to copy everything!
    double lc_timestamp;
    size_t image_size, points_size;
    bool has_new_lc = false;
    
    {
      std::lock_guard<std::mutex> lk(m_lc);
      lc_timestamp = lc_data.timestamp;
      points_size = lc_data.points_size;
      image_size = lc_data.image_size; 
      if (lc_timestamp != last_lc_timestamp) {
        last_lc_timestamp = lc_timestamp;
        has_new_lc = true;
        if (points_size > 0) {
          rerun_log_points(&lc_data);
        }
      }
    }

        // std::cout << "T:" << imu_copy.acc_timestamp << " acc:" << imu_copy.acc_x << "," << imu_copy.acc_y << "," << imu_copy.acc_z << std::endl
        //             << "T:" << imu_copy.gyro_timestamp << " gyro:" << imu_copy.gyro_x << "," << imu_copy.gyro_y << "," << imu_copy.gyro_z <<
        //             std::endl;
        if (has_new_lc) {
          std::cout << "T:" << lc_timestamp << " points size: " << points_size << ", image size: " << image_size << std::endl;
        }
  }
};
