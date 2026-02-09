#include "core/telemetry.h"
#include <algorithm>
#include <math.h>
#include <mutex>
#include <stdint.h>


void log_config(const sensors::CameraConfig& cam_config){
  std::cout << "Sensor config" << std::endl;
  std::cout << "T: " << cam_config.timestamp << ", height: " << cam_config.image_height << ", width: " << cam_config.image_width << ", channels: " << cam_config.image_channels << std::endl;
}


void log_imu(std::mutex& m_imu, const sensors::IMUData& imu_copy, double& last_imu_timestamp){
  std::cout << std::fixed << std::setprecision(5);
  
  if (imu_copy.timestamp <= last_imu_timestamp) {
    std::this_thread::yield();
    return;
  }
  last_imu_timestamp = imu_copy.timestamp;
  rerun_log_imu(&imu_copy);
  // std::cout << "T:" << imu_copy.timestamp << " acc:" << imu_copy.acc_x << "," << imu_copy.acc_y << "," << imu_copy.acc_z << std::endl
  // << "T:" << imu_copy.timestamp << " gyro:" << imu_copy.gyro_x << "," << imu_copy.gyro_y << "," << imu_copy.gyro_z <<
  // std::endl;
  // std::this_thread::sleep_for(std::chrono::milliseconds(IMUIntervalMs));
}
// log sensors without significant delays in processing
void log_lc(std::mutex& m_lc, const sensors::LidarCameraData& lc_data, double& last_lc_timestamp){
  std::cout << std::fixed << std::setprecision(5);
    
  // very expensive to copy everything!
  {
    std::lock_guard<std::mutex> lk(m_lc);
    const double lc_timestamp = lc_data.timestamp;
    if (lc_timestamp <= last_lc_timestamp){
      std::this_thread::yield();
      return;
    }
    if (lc_timestamp - last_lc_timestamp < kLidarLogIntervalSec) {
      return;
    }
    last_lc_timestamp = lc_timestamp;

  }


};
