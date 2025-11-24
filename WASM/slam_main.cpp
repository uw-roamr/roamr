#include <mutex>
#include <thread>
#include <chrono>

#include "imu.h"
#include "lidar_camera.h"
#include "telemetry.h"

int main(){
    std::mutex m_imu;
    IMUData imu_data;
    std::mutex m_lc;
    LidarCameraData lc_data;

    std::thread imu_thread([&m_imu, &imu_data](){
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(IMUIntervalMs));
            std::lock_guard<std::mutex> lk(m_imu);
            read_imu(&imu_data);
        }
    });
    std::thread lidar_camera_thread([&m_lc, &lc_data](){
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(LidarCameraIntervalMs));
            std::lock_guard<std::mutex> lk(m_lc);
            read_lidar_camera(&lc_data);
        }
    });
    std::thread telemetry_thread(log_sensors, std::ref(m_imu), std::cref(imu_data), std::ref(m_lc), std::cref(lc_data));

    imu_thread.join();
    lidar_camera_thread.join();
    telemetry_thread.join();
}
