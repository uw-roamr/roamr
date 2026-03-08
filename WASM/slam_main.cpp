#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

#include "controls/motors.h"
#include "controls/path_following.h"
#include "core/telemetry.h"
#include "mapping/map_update.h"
#include "planning/planner_bridge.h"
#include "sensors/calibration.h"
#include "sensors/imu.h"
#include "sensors/imu_preintegration.h"
#include "sensors/lidar_camera.h"
#include "sensors/wheel_odometry.h"

enum class RobotState{
    SENSOR_INIT,
    AUTONOMY_INIT,
    AUTONOMY_ENGAGED
};
static std::atomic<RobotState> g_state{RobotState::SENSOR_INIT};

static bool g_map_initialized = false;
static mapping::MapFrame g_map_frame;
static std::atomic<bool> g_first_map_update_done{false};

// lidar camera globals
static sensors::CameraConfig g_cam_config;
static sensors::LidarCameraData g_lc_buffers[2];
static std::atomic<int> g_lc_ready_idx{-1};
static std::atomic<int> g_lc_in_use_idx{-1};
static sensors::LidarCameraData g_rerun_lc;
static std::atomic<bool> g_lc_ready{false};

// IMU globals
static sensors::calibration::IMUHistoryBuffer g_imu_history;
static sensors::calibration::IMUCalibration g_imu_calib(g_imu_history);
static sensors::IMUPreintegrator g_imu_preintegrator(g_imu_calib);
static core::Vector4d g_latest_quat_imu = core::quat_identity();
static std::atomic<bool> g_imu_ready{false};

// motor encoder odometry globals
static core::Vector3d g_latest_translation_odom = {0.0, 0.0, 0.0};
static core::Vector4d g_latest_quat_odom = core::quat_identity();

static sensors::PoseLog g_pose;
enum class PoseSource{
    IMU,
    wheel_odom,
    fused
};
static constexpr PoseSource pose_source = PoseSource::wheel_odom;
static constexpr bool kEnableOdomTurnDemo = false;
static constexpr double kOdomTurnDeltaYawRad = sensors::kTwoPi;
static constexpr int32_t kOdomTurnDirection = 1;  // +1 CCW, -1 CW
static constexpr int32_t kOdomTurnHoldMs = 120;
static constexpr int32_t kOdomTurnSettledSamples = 3;
static constexpr int32_t kOdomTurnTimeoutMs = 15000;

// Tiny planner demo: set a fixed map-view pixel goal at startup.
// Toggle off when using host-provided goal clicks.
static constexpr bool kEnablePlannerDemoGoal = true;
static constexpr int kPlannerDemoGoalPixelX = 160;
static constexpr int kPlannerDemoGoalPixelY = 128;


int main(){
    std::mutex m_imu;
    std::mutex m_lc;
    std::mutex m_pose;

    controls::MotorController motors;
    motors.stop(); // ensure motors start from a safe state

    init_camera(&g_cam_config);
    log_config(g_cam_config);

    if (kEnablePlannerDemoGoal) {
        planning::bridge::set_goal_map_pixel(
            kPlannerDemoGoalPixelX,
            kPlannerDemoGoalPixelY);
    } else {
        planning::bridge::clear_goal();
    }

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
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(sensors::IMUIntervalMs)));
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
            g_latest_quat_imu = g_imu_preintegrator.pose().quaternion;
            if (pose_source == PoseSource::IMU){
                sensors::PoseLog pose_copy = {};
                {
                    std::lock_guard<std::mutex> lk(m_pose);
                    g_imu_preintegrator.get_pose_log(&g_pose);
                    pose_copy = g_pose;
                }
                rerun_log_pose(&pose_copy);
            }
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
                if (g_lc_buffers[write_idx].points_size > 0) {
                    if (!g_lc_ready.load(std::memory_order_relaxed)) {
                        g_lc_ready.store(true, std::memory_order_release);
                    }
                    g_lc_ready_idx.store(write_idx, std::memory_order_release);
                }
                write_idx = 1 - write_idx;
            }
        }
    });


    std::thread mapping_thread([&m_lc, &m_pose](){
      using Clock = std::chrono::steady_clock;
      auto elapsed_ms = [](const Clock::time_point& start, const Clock::time_point& end) {
        return std::chrono::duration<double, std::milli>(end - start).count();
      };

      double g_last_map_timestamp = -1.0;
      double map_timestamp = -1;
      auto perf_window_start = Clock::now();
      int perf_frames_with_points = 0;
      int perf_rerun_emits = 0;
      int perf_map_updates = 0;
      double perf_rerun_build_ms_sum = 0.0;
      double perf_rerun_log_ms_sum = 0.0;
      double perf_map_update_ms_sum = 0.0;

      while (!g_imu_ready.load(std::memory_order_acquire)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      while(true){

        core::PoseSE3d body_to_world;
        {
            std::lock_guard<std::mutex> lk(m_pose);
            body_to_world.quaternion = g_pose.quaternion;
            body_to_world.translation = g_pose.translation;
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
        perf_frames_with_points += 1;

        const auto rerun_build_start = Clock::now();
        mapping::build_rerun_frame_from_lidar(lc_data, g_rerun_lc, body_to_world);
        const auto rerun_build_end = Clock::now();
        perf_rerun_build_ms_sum += elapsed_ms(rerun_build_start, rerun_build_end);
        map_timestamp = lc_data.timestamp;
        const bool do_map_update = (map_timestamp - g_last_map_timestamp >= mapping::mapMinInterval);
        if (!do_map_update) {
            g_lc_in_use_idx.store(-1, std::memory_order_release);
            continue;
        }
        g_last_map_timestamp = map_timestamp;
        const auto map_update_start = Clock::now();
        mapping::update_map_from_lidar(
            lc_data,
            g_map_frame,
            g_map_initialized,
            body_to_world
        );
        if (!g_first_map_update_done.load(std::memory_order_relaxed)) {
            g_first_map_update_done.store(true, std::memory_order_release);
        }
        const auto map_update_end = Clock::now();
        perf_map_update_ms_sum += elapsed_ms(map_update_start, map_update_end);
        perf_map_updates += 1;
        planning::bridge::update_plan_overlay(
            body_to_world,
            g_map_frame.width,
            g_map_frame.height);
        g_lc_in_use_idx.store(-1, std::memory_order_release);

        if (g_rerun_lc.points_size > 0) {
            const auto rerun_log_start = Clock::now();
            rerun_log_lidar_frame(&g_rerun_lc);
            const auto rerun_log_end = Clock::now();
            perf_rerun_log_ms_sum += elapsed_ms(rerun_log_start, rerun_log_end);
            perf_rerun_emits += 1;
        }

        const auto now = Clock::now();
        const double window_sec = std::chrono::duration<double>(now - perf_window_start).count();
        if (window_sec >= 2.0) {
            const double frames_rate = static_cast<double>(perf_frames_with_points) / std::max(1e-6, window_sec);
            const double rerun_rate = static_cast<double>(perf_rerun_emits) / std::max(1e-6, window_sec);
            const double map_rate = static_cast<double>(perf_map_updates) / std::max(1e-6, window_sec);

            const int frames_denom = std::max(1, perf_frames_with_points);
            const int rerun_denom = std::max(1, perf_rerun_emits);
            const int map_denom = std::max(1, perf_map_updates);
            const double rerun_build_avg_ms = perf_rerun_build_ms_sum / frames_denom;
            const double rerun_log_avg_ms = perf_rerun_log_ms_sum / rerun_denom;
            const double map_update_avg_ms = perf_map_update_ms_sum / map_denom;

            // std::cout << "[mapping][thread] "
            //           << "frames=" << frames_rate << "/s"
            //           << " rerun_emit=" << rerun_rate << "/s"
            //           << " map_update=" << map_rate << "/s"
            //           << " rerun_build_ms=" << rerun_build_avg_ms
            //           << " rerun_log_ms=" << rerun_log_avg_ms
            //           << " map_update_ms=" << map_update_avg_ms
            //           << std::endl;

            perf_window_start = now;
            perf_frames_with_points = 0;
            perf_rerun_emits = 0;
            perf_map_updates = 0;
            perf_rerun_build_ms_sum = 0.0;
            perf_rerun_log_ms_sum = 0.0;
            perf_map_update_ms_sum = 0.0;
        }

      }
    });

    std::thread control_thread([&m_pose, &motors](){
        // responsible for reading encoder values and sending motor commands
        sensors::WheelOdometryData odom = {};
        controls::PathFollower path_follower;
        std::vector<core::Vector3d> planned_path_world;
        uint64_t planned_path_revision = 0;
        double x = 0.0;
        double y = 0.0;
        double yaw = 0.0;
        bool turn_active = false;
        bool turn_done = !kEnableOdomTurnDemo;
        double turn_target_yaw = 0.0;
        int settled_samples = 0;
        auto turn_start = std::chrono::steady_clock::now();
        controls::TurnInPlaceConfig turn_cfg{};

        while(true){
            read_wheel_odometry(&odom);
            if (odom.seq < 0 || odom.timestamp <= 0.0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
                continue;
            }

            sensors::integrate_wheel_odometry(odom, &x, &y, &yaw);
            g_latest_translation_odom = {x, y, 0.0};
            g_latest_quat_odom = {0.0, 0.0, std::sin(yaw * 0.5), std::cos(yaw * 0.5)};

            if (!turn_done) {
                if (!turn_active) {
                    const double sign = (kOdomTurnDirection >= 0) ? 1.0 : -1.0;
                    turn_target_yaw = yaw + (sign * kOdomTurnDeltaYawRad);
                    turn_active = true;
                    settled_samples = 0;
                    turn_start = std::chrono::steady_clock::now();
                    motors.reset_twist_controller();
                }

                const bool reached = motors.drive_turn_to_yaw(
                    yaw,
                    turn_target_yaw,
                    odom,
                    turn_cfg,
                    kOdomTurnHoldMs);
                if (reached) {
                    settled_samples += 1;
                    if (settled_samples >= kOdomTurnSettledSamples) {
                        turn_done = true;
                        turn_active = false;
                        motors.stop();
                        motors.reset_twist_controller();
                    }
                } else {
                    settled_samples = 0;
                }

                const int64_t elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - turn_start).count();
                if (turn_active && elapsed_ms > kOdomTurnTimeoutMs) {
                    turn_done = true;
                    turn_active = false;
                    motors.stop();
                    motors.reset_twist_controller();
                }
            }

            if (pose_source == PoseSource::wheel_odom){
                sensors::PoseLog pose_copy = {};
                {
                    std::lock_guard<std::mutex> lk(m_pose);
                    g_pose.timestamp = odom.timestamp;
                    g_pose.translation = g_latest_translation_odom;
                    g_pose.quaternion = g_latest_quat_odom;
                    pose_copy = g_pose;
                }
                // rerun_log_pose(&pose_copy);
                rerun_log_pose_wheel(&pose_copy);
            }
            // rerun_log_pose_wheel(&wheel_pose);
        }
    });

    
    std::thread autonomy_thread([](){
        // the main high level thread
        while(!g_imu_ready.load(std::memory_order_acquire) ||
              !g_lc_ready.load(std::memory_order_acquire)
        // || !g_wheel_odom_ready
        ){
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        g_state.store(RobotState::AUTONOMY_INIT, std::memory_order_release);
        while(!g_first_map_update_done.load(std::memory_order_acquire)){
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        g_state.store(RobotState::AUTONOMY_ENGAGED, std::memory_order_release);
    });

    // TODO: remove once autonomy control loop is closed
    // controls::drive_forward_demo();
    // controls::drive_twist_demo();

    imu_thread.join();
    lidar_camera_thread.join();
    mapping_thread.join();
    control_thread.join();
    autonomy_thread.join();
}
