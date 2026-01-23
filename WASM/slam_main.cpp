#include <mutex>
#include <thread>
#include <chrono>

#include "imu.h"
#include "lidar_camera.h"
#include "telemetry.h"

static CameraConfig g_cam_config;
static LidarCameraData g_lc_data;
static IMUData g_imu_data;

int main(){
    std::mutex m_imu;
    
    std::mutex m_lc;

    init_camera(&g_cam_config);
    log_config(g_cam_config);

    std::thread imu_thread([&m_imu](){
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(IMUIntervalMs));
            std::lock_guard<std::mutex> lk(m_imu);
            read_imu(&g_imu_data);
        }
    });
    std::thread lidar_camera_thread([&m_lc](){
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(LidarCameraIntervalMs));
            std::lock_guard<std::mutex> lk(m_lc);
            read_lidar_camera(&g_lc_data);
        }
    });
    std::thread telemetry_thread(log_sensors, std::ref(m_imu), std::cref(g_imu_data), std::ref(m_lc), std::cref(g_lc_data));

    imu_thread.join();
    lidar_camera_thread.join();
    telemetry_thread.join();
}
