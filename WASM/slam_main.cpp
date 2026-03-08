#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iostream>
#include <mutex>
#include <sstream>
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
static std::atomic<uint64_t> g_map_update_revision{0};

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
static std::atomic<bool> g_wheel_odom_ready{false};
static std::mutex g_latest_wheel_odom_mutex;
static sensors::WheelOdometryData g_latest_wheel_odom = {0.0, -1, 0, 0, 0};

static bool read_latest_wheel_odom_snapshot(sensors::WheelOdometryData* out) {
    if (!out) {
        return false;
    }
    std::lock_guard<std::mutex> lk(g_latest_wheel_odom_mutex);
    if (g_latest_wheel_odom.seq < 0 ||
        g_latest_wheel_odom.timestamp <= 0.0 ||
        g_latest_wheel_odom.sample_period_ms <= 0) {
        return false;
    }
    *out = g_latest_wheel_odom;
    return true;
}

static sensors::PoseLog g_pose;
enum class PoseSource{
    IMU,
    wheel_odom,
    fused
};
// IMU preintegration drifts over time, so the shared autonomy/map pose should
// not treat it as a drop-in orientation estimate.
static constexpr PoseSource pose_source = PoseSource::wheel_odom;
static constexpr bool kEnableInitialSpin = true;
static std::atomic<bool> g_initial_spin_done{!kEnableInitialSpin};
static constexpr int32_t kInitialSpinSegments = 4;
static constexpr int32_t kInitialSpinHoldMs = 120;
static constexpr int32_t kInitialSpinMapWaitTimeoutMs = 1500;
static constexpr double kInitialSpinStepRad = core::pi * 0.5;
static constexpr controls::TurnInPlaceConfig kInitialSpinTurnCfg{
    2.2,
    1.2,
    0.25,
    4.0 * core::pi / 180.0};
static constexpr int32_t kPathFollowHoldMs = 120;
static constexpr bool kEnableWheelPoseLogging = true;
static constexpr double kWheelPoseLogIntervalSec = 0.2;
static constexpr bool kEnableVerboseAutonomyLogs = false;

// Tiny planner demo: set a fixed map-view pixel goal at startup.
// Toggle off when using host-provided goal clicks.
static constexpr bool kEnablePlannerDemoGoal = false;
static constexpr int kPlannerDemoGoalPixelX = 160;
static constexpr int kPlannerDemoGoalPixelY = 128;


int main(){
    std::mutex m_imu;
    std::mutex m_lc;
    std::mutex m_pose;

    controls::MotorController motors;
    motors.set_odom_reader(read_latest_wheel_odom_snapshot);
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
        double last_lc_frame_timestamp = -1.0;
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
                g_lc_buffers[write_idx].timestamp = 0.0;
                g_lc_buffers[write_idx].points_size = 0;
                g_lc_buffers[write_idx].colors_size = 0;
                g_lc_buffers[write_idx].image_size = 0;
                read_lidar_camera(&g_lc_buffers[write_idx]);
                sensors::ensure_points_flu(g_lc_buffers[write_idx]);
                if (g_lc_buffers[write_idx].points_size > 0 &&
                    g_lc_buffers[write_idx].timestamp > last_lc_frame_timestamp) {
                    last_lc_frame_timestamp = g_lc_buffers[write_idx].timestamp;
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

      while (g_state != RobotState::AUTONOMY_ENGAGED && g_state != RobotState::AUTONOMY_INIT) {
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
        g_map_update_revision.fetch_add(1, std::memory_order_acq_rel);
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

            std::cout << "[mapping][thread] "
                      << "frames=" << frames_rate << "/s"
                      << " rerun_emit=" << rerun_rate << "/s"
                      << " map_update=" << map_rate << "/s"
                      << " rerun_build_ms=" << rerun_build_avg_ms
                      << " rerun_log_ms=" << rerun_log_avg_ms
                      << " map_update_ms=" << map_update_avg_ms
                      << std::endl;

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
        using Clock = std::chrono::steady_clock;
        sensors::WheelOdometryData odom = {};
        controls::PathFollower path_follower;
        std::vector<core::Vector3d> planned_path_world;
        uint64_t planned_path_revision = 0;
        double x = 0.0;
        double y = 0.0;
        double yaw_odom = 0.0;
        double last_wheel_pose_log_timestamp = -1.0;
        bool spin_target_active = false;
        bool waiting_for_map_cycle = false;
        bool goal_reached_logged = false;
        int initial_spin_segment_index = 0;
        uint64_t last_seen_map_revision = 0;
        double spin_target_yaw = 0.0;
        Clock::time_point initial_spin_map_wait_deadline{};

        while(true){
            read_wheel_odometry(&odom);
            if (odom.seq < 0 || odom.timestamp <= 0.0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
                continue;
            }
            if (!g_wheel_odom_ready.load(std::memory_order_relaxed)) {
                g_wheel_odom_ready.store(true, std::memory_order_release);
            }

            {
                std::lock_guard<std::mutex> lk(g_latest_wheel_odom_mutex);
                g_latest_wheel_odom = odom;
            }

            sensors::integrate_wheel_odometry(odom, &x, &y, &yaw);
            g_latest_translation_odom = {x, y, 0.0};
            g_latest_quat_odom = {
                0.0, 0.0, std::sin(yaw_odom * 0.5), std::cos(yaw_odom * 0.5)};

            sensors::PoseLog pose_copy = {};
            {
                std::lock_guard<std::mutex> lk(m_pose);
                g_pose.timestamp = odom.timestamp;
                g_pose.translation = g_latest_translation_odom;
                g_pose.quaternion = g_latest_quat_odom;
                pose_copy = g_pose;
            }
            if (kEnableWheelPoseLogging &&
                (last_wheel_pose_log_timestamp < 0.0 ||
                 (odom.timestamp - last_wheel_pose_log_timestamp) >= kWheelPoseLogIntervalSec)) {
                rerun_log_pose_wheel(&pose_copy);
                last_wheel_pose_log_timestamp = odom.timestamp;
            }
            if (pose_source != PoseSource::wheel_odom) {
                rerun_log_pose(&pose_copy);
            }

            const RobotState state = g_state.load(std::memory_order_acquire);
            if (state == RobotState::AUTONOMY_INIT &&
                !g_initial_spin_done.load(std::memory_order_acquire)) {
                if (!g_lc_ready.load(std::memory_order_acquire) ||
                    !g_first_map_update_done.load(std::memory_order_acquire)) {
                    continue;
                }

                if (waiting_for_map_cycle) {
                    const uint64_t current_map_revision =
                        g_map_update_revision.load(std::memory_order_acquire);
                    if (current_map_revision > last_seen_map_revision) {
                        waiting_for_map_cycle = false;
                        if (initial_spin_segment_index >= kInitialSpinSegments) {
                            g_initial_spin_done.store(true, std::memory_order_release);
                            motors.stop();
                            std::ostringstream done_log;
                            done_log << "[autonomy][spin] completed final_yaw="
                                     << yaw_odom
                                     << " map_revision=" << current_map_revision;
                            wasm_log_line(done_log.str());
                        } else if (kEnableVerboseAutonomyLogs) {
                            std::ostringstream resume_log;
                            resume_log << "[autonomy][spin] map update observed after segment="
                                       << initial_spin_segment_index
                                       << " revision=" << current_map_revision;
                            wasm_log_line(resume_log.str());
                        }
                    } else if (Clock::now() >= initial_spin_map_wait_deadline) {
                        waiting_for_map_cycle = false;
                        std::ostringstream timeout_log;
                        timeout_log << "[autonomy][spin] map wait timeout after segment="
                                    << initial_spin_segment_index
                                    << " revision=" << current_map_revision;
                        wasm_log_line(timeout_log.str());
                    }
                    continue;
                }

                if (initial_spin_segment_index >= kInitialSpinSegments) {
                    g_initial_spin_done.store(true, std::memory_order_release);
                    motors.stop();
                    continue;
                }

                if (!spin_target_active) {
                    spin_target_active = true;
                    spin_target_yaw = yaw_odom + kInitialSpinStepRad;
                    if (kEnableVerboseAutonomyLogs) {
                        std::ostringstream start_log;
                        start_log << "[autonomy][spin] start segment="
                                  << (initial_spin_segment_index + 1) << "/" << kInitialSpinSegments
                                  << " current_yaw=" << yaw_odom
                                  << " target_yaw=" << spin_target_yaw;
                        wasm_log_line(start_log.str());
                    }
                }

                const bool reached = motors.drive_turn_to_yaw(
                    yaw_odom,
                    spin_target_yaw,
                    odom,
                    kInitialSpinTurnCfg,
                    kInitialSpinHoldMs);
                if (reached) {
                    motors.stop();
                    spin_target_active = false;
                    initial_spin_segment_index += 1;
                    waiting_for_map_cycle = true;
                    last_seen_map_revision =
                        g_map_update_revision.load(std::memory_order_acquire);
                    initial_spin_map_wait_deadline =
                        Clock::now() + std::chrono::milliseconds(kInitialSpinMapWaitTimeoutMs);
                    if (kEnableVerboseAutonomyLogs) {
                        std::ostringstream stop_log;
                        stop_log << "[autonomy][spin] reached segment="
                                 << initial_spin_segment_index
                                 << " yaw=" << yaw_odom
                                 << " waiting_for_map_revision>" << last_seen_map_revision;
                        wasm_log_line(stop_log.str());
                    }
                }
                continue;
            }

            if (state != RobotState::AUTONOMY_ENGAGED) {
                continue;
            }

            const uint64_t latest_path_revision =
                planning::bridge::copy_latest_plan_world(&planned_path_world);
            if (latest_path_revision != planned_path_revision) {
                planned_path_revision = latest_path_revision;
                goal_reached_logged = false;
                if (!planned_path_world.empty()) {
                    path_follower.set_path(planned_path_world);
                    if (kEnableVerboseAutonomyLogs) {
                        std::ostringstream path_log;
                        path_log << "[autonomy][path] updated revision="
                                 << planned_path_revision
                                 << " waypoints=" << planned_path_world.size();
                        wasm_log_line(path_log.str());
                    }
                } else {
                    path_follower.clear_path();
                    motors.stop();
                }
            }

            if (!path_follower.has_path()) {
                motors.stop();
                continue;
            }

            const controls::Pose2D fused_pose{x, y, yaw_odom};
            const double dt_seconds = std::max(
                1e-3,
                static_cast<double>(std::max(1, odom.sample_period_ms)) * 1e-3);
            const controls::PathFollowerStatus status =
                path_follower.update(fused_pose, dt_seconds, kPathFollowHoldMs);
            if (status.goal_reached) {
                if (!goal_reached_logged) {
                    goal_reached_logged = true;
                    wasm_log_line("[autonomy][path] goal reached");
                }
                path_follower.clear_path();
                motors.stop();
                continue;
            }
            goal_reached_logged = false;
            motors.drive_twist(status.command, odom);
        }
    });


    std::thread autonomy_thread([](){
        // the main high level thread
        while(!g_imu_ready.load(std::memory_order_acquire) ||
              !g_lc_ready.load(std::memory_order_acquire)
              || !g_wheel_odom_ready.load(std::memory_order_acquire)
        ){
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        wasm_log_line("SENSOR_INIT -> AUTONOMY_INIT");
        g_state.store(RobotState::AUTONOMY_INIT, std::memory_order_release);
        while(!g_first_map_update_done.load(std::memory_order_acquire) ||
              !g_initial_spin_done.load(std::memory_order_acquire)){
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        wasm_log_line("AUTONOMY_INIT -> AUTONOMY_ENGAGED");
        g_state.store(RobotState::AUTONOMY_ENGAGED, std::memory_order_release);
    });

    // TODO: remove once autonomy control loop is closed
    // controls::drive_forward_demo();
    controls::drive_twist_demo(motors);

    imu_thread.join();
    lidar_camera_thread.join();
    mapping_thread.join();
    control_thread.join();
    autonomy_thread.join();
}
