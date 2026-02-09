#include <mutex>
#include <thread>
#include <chrono>

#include "controls/motors.h"
#include "core/telemetry.h"
#include "sensors/calibration.h"
#include "sensors/imu.h"
#include "sensors/lidar_camera.h"
#include "mapping/map_api.h"
#include "mapping/map_update.h"

static bool g_map_initialized = false;
static mapping::MapFrame g_map_frame;

static sensors::CameraConfig g_cam_config;
static sensors::LidarCameraData g_lc_data;
static sensors::LidarCameraData g_rerun_lc;

static sensors::calibration::IMUHistoryBuffer g_imu_history;
static sensors::calibration::IMUCalibration g_imu_calib(g_imu_history);

// Quick demo: drive both wheels forward briefly.
void drive_forward_demo() {
    controls::MotorController motors;
    
    // Ramp from reverse to forward with a dwell at each step.
    for (int i = -2; i <= 3; i++){
        const int pct = i * 10;
        motors.drive_for(-pct, pct, 3000, true);
    }
    motors.stop();
}

int main(){
    std::mutex m_imu;
    std::mutex m_lc;

    controls::MotorController motors;
    motors.stop(); // ensure motors start from a safe state

    init_camera(&g_cam_config);
    log_config(g_cam_config);

    std::thread imu_thread([&m_imu](){
        double g_last_logged_imu_timestamp = -1.0;

        g_imu_calib.init_biases();
        static sensors::IMUData imu_copy;
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(sensors::IMUIntervalMs / 2.0)));
            {
                std::lock_guard<std::mutex> lk(m_imu);
                read_imu(&g_imu_calib.new_write_slot());
                g_imu_calib.update();
                g_imu_calib.recalibrate(); // if possible, update biases
                imu_copy = g_imu_calib.curr_slot();
            }
            log_imu(m_imu, imu_copy, g_last_logged_imu_timestamp);
        }
    });
    std::thread lidar_camera_thread([&m_lc](){
        double g_last_logged_lc_timestamp = -1.0;
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(sensors::LidarCameraIntervalMs)));
            {
                std::lock_guard<std::mutex> lk(m_lc);
                read_lidar_camera(&g_lc_data);
            }
            // log_lc(m_lc, g_lc_data, g_last_logged_lc_timestamp);
        }
    });


    std::thread mapping_thread([&m_lc](){
      double g_last_map_timestamp = -1.0;
      double map_timestamp = -1;
      while(true){
        {
            {
                std::lock_guard<std::mutex> lk(m_lc);
                if (g_lc_data.points_size <= 0) continue;
                map_timestamp = g_lc_data.timestamp;
            
                const bool do_map_update = (map_timestamp - g_last_map_timestamp >= mapping::mapMinInterval);
                if (!do_map_update) continue;
                g_last_map_timestamp = map_timestamp;
                // mapping::update_map_from_lidar(g_lc_data, g_map_frame, &g_rerun_lc, do_map_update, g_map_initialized);
            }

            // if (g_rerun_lc.points_size > 0) {
            //     rerun_log_lidar_frame(&g_rerun_lc);
            // }
        
        }
      }
    });

    drive_forward_demo();
    imu_thread.join();
    lidar_camera_thread.join();
    mapping_thread.join();
}
