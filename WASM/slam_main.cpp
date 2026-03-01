#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <thread>

#include "controls/motors.h"
#include "core/telemetry.h"
#include "sensors/calibration.h"
#include "sensors/imu.h"
#include "sensors/imu_preintegration.h"
#include "sensors/lidar_camera.h"
#include "sensors/wheel_odometry.h"
#include "mapping/map_api.h"
#include "mapping/map_update.h"

static bool g_map_initialized = false;
static mapping::MapFrame g_map_frame;

static sensors::CameraConfig g_cam_config;
static sensors::LidarCameraData g_lc_buffers[2];
static std::atomic<int> g_lc_ready_idx{-1};
static std::atomic<int> g_lc_in_use_idx{-1};
static sensors::LidarCameraData g_rerun_lc;

static sensors::calibration::IMUHistoryBuffer g_imu_history;
static sensors::calibration::IMUCalibration g_imu_calib(g_imu_history);
static sensors::IMUPreintegrator g_imu_preintegrator(g_imu_calib);

static sensors::PoseLog g_pose;
static core::Vector4d g_latest_quat = {0.0, 0.0, 0.0, 1.0};
static std::atomic<bool> g_imu_ready{false};

namespace {
constexpr double kWheelTicksPerRev = 16384.0;
constexpr double kWheelRadiusMeters = 0.03;
constexpr double kWheelBaseMeters = 0.18;
constexpr double kTwoPi = 6.28318530717958647692;

void integrate_wheel_odometry(
    const sensors::WheelOdometryData& odom,
    double* x,
    double* y,
    double* yaw) {
    if (!x || !y || !yaw) {
        return;
    }
    const double meters_per_tick = (kTwoPi * kWheelRadiusMeters) / kWheelTicksPerRev;
    const double dl = static_cast<double>(odom.dl_ticks) * meters_per_tick;
    const double dr = static_cast<double>(odom.dr_ticks) * meters_per_tick;

    const double ds = 0.5 * (dl + dr);
    const double dtheta = (dr - dl) / kWheelBaseMeters;
    const double heading_mid = *yaw + (0.5 * dtheta);

    *x += ds * std::cos(heading_mid);
    *y += ds * std::sin(heading_mid);
    *yaw += dtheta;
}
} // namespace

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
    std::mutex m_pose;

    controls::MotorController motors;
    motors.stop(); // ensure motors start from a safe state

    init_camera(&g_cam_config);
    log_config(g_cam_config);

    std::thread imu_thread([&m_imu, &m_pose](){
        double g_last_logged_imu_timestamp = -1.0;
        double g_last_calib_timestamp = -1.0;

        g_imu_calib.init_biases();
        g_imu_preintegrator.reset();
        g_imu_preintegrator.init_from_calibration();
        g_last_calib_timestamp = g_imu_calib.last_calibrated;
        g_imu_ready.store(true, std::memory_order_release);
        static sensors::IMUData imu_copy;
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(sensors::IMUIntervalMs / 2.0)));
            {
                std::lock_guard<std::mutex> lk(m_imu);
                read_imu(&g_imu_calib.new_write_slot());
                g_imu_calib.update();
                g_imu_calib.recalibrate(); // if possible, update biases
                if (g_imu_calib.last_calibrated > g_last_calib_timestamp) {
                    g_last_calib_timestamp = g_imu_calib.last_calibrated;
                    g_imu_preintegrator.init_from_calibration();
                }
                imu_copy = g_imu_calib.curr_slot();
            }
            g_imu_preintegrator.integrate(imu_copy);
            {
                std::lock_guard<std::mutex> lk(m_pose);
                g_latest_quat = g_imu_preintegrator.pose().quaternion;
            }
            g_imu_preintegrator.get_pose_log(&g_pose);
            // log_imu(m_imu, imu_copy, g_last_logged_imu_timestamp);
        }
    });
    std::thread lidar_camera_thread([&m_lc](){
        double g_last_logged_lc_timestamp = -1.0;
        int write_idx = 0;
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(sensors::LidarCameraIntervalMs)));
            {
                const int in_use = g_lc_in_use_idx.load(std::memory_order_acquire);
                if (write_idx == in_use) {
                    write_idx = 1 - write_idx;
                }
                if (write_idx == in_use) {
                    std::this_thread::yield();
                    continue;
                }
                read_lidar_camera(&g_lc_buffers[write_idx]);
                sensors::ensure_points_flu(g_lc_buffers[write_idx]);
                g_lc_ready_idx.store(write_idx, std::memory_order_release);
                write_idx = 1 - write_idx;
            }
            // log_lc(m_lc, g_lc_data, g_last_logged_lc_timestamp);
        }
    });


    std::thread mapping_thread([&m_lc, &m_pose](){
      double g_last_map_timestamp = -1.0;
      double map_timestamp = -1;
      while (!g_imu_ready.load(std::memory_order_acquire)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      while(true){

        core::Vector4d q_body_to_world = {0.0, 0.0, 0.0, 1.0};
        {
            std::lock_guard<std::mutex> lk(m_pose);
            q_body_to_world = g_latest_quat;
        }

        const int ready_idx = g_lc_ready_idx.exchange(-1, std::memory_order_acq_rel);
        if (ready_idx < 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        g_lc_in_use_idx.store(ready_idx, std::memory_order_release);
        const sensors::LidarCameraData& lc_data = g_lc_buffers[ready_idx];
        if (lc_data.points_size <= 0) {
            g_lc_in_use_idx.store(-1, std::memory_order_release);
            continue;
        }
        map_timestamp = lc_data.timestamp;
        const bool do_map_update = (map_timestamp - g_last_map_timestamp >= mapping::mapMinInterval);
        if (!do_map_update) {
            g_lc_in_use_idx.store(-1, std::memory_order_release);
            continue;
        }
        g_last_map_timestamp = map_timestamp;
        mapping::update_map_from_lidar(lc_data, g_map_frame, &g_rerun_lc, do_map_update, g_map_initialized, q_body_to_world);
        g_lc_in_use_idx.store(-1, std::memory_order_release);

        if (g_rerun_lc.points_size > 0) {
            rerun_log_lidar_frame(&g_rerun_lc);
        }

      }
    });

    std::thread wheel_odom_thread([](){
        sensors::WheelOdometryData odom = {};
        sensors::PoseLog wheel_pose = {};
        double x = 0.0;
        double y = 0.0;
        double yaw = 0.0;

        while (true) {
            read_wheel_odometry(&odom);
            if (odom.seq < 0 || odom.timestamp <= 0.0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
                continue;
            }

            integrate_wheel_odometry(odom, &x, &y, &yaw);
            wheel_pose.timestamp = odom.timestamp;
            wheel_pose.translation = {x, y, 0.0};
            wheel_pose.quaternion = {0.0, 0.0, std::sin(yaw * 0.5), std::cos(yaw * 0.5)};
            rerun_log_pose(&wheel_pose);
        }
    });

    drive_forward_demo();
    imu_thread.join();
    lidar_camera_thread.join();
    mapping_thread.join();
    wheel_odom_thread.join();
}
