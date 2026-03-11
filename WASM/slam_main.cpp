#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <iostream>
#include <limits>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#include "autonomy/autonomy.h"
#include "controls/motors.h"
#include "core/math_utils.h"
#include "core/ring_buffer.h"
#include "controls/path_following.h"
#include "core/telemetry.h"
#include "mapping/map_update.h"
#include "mapping/visualization.h"
#include "planning/planner_bridge.h"
#include "sensors/calibration.h"
#include "sensors/imu.h"
#include "sensors/imu_preintegration.h"
#include "sensors/lidar_camera.h"
#include "sensors/wheel_odometry.h"

namespace {

enum class RobotState{
    SENSOR_INIT,
    AUTONOMY_INIT,
    AUTONOMY_ENGAGED
};
static std::atomic<RobotState> g_state{RobotState::SENSOR_INIT};

static std::atomic<autonomy::AutonomySubstate> g_autonomy_substate{autonomy::AutonomySubstate::IDLE};
static std::atomic<bool> g_planner_initialized{false};

static mapping::Map g_map;
static mapping::MapImage g_map_image;
static std::mutex g_map_mutex;
static std::atomic<bool> g_first_map_update_done{false};
static std::atomic<uint64_t> g_map_update_revision{0};
static std::mutex g_map_publish_mutex;
static mapping::MapSnapshot g_latest_map_snapshot;
static std::mutex g_plan_publish_mutex;
static planning::bridge::PlanningOverlay g_latest_plan_overlay;
static std::mutex g_planner_wake_mutex;
static std::condition_variable g_planner_wake_cv;
static uint64_t g_planner_wake_revision = 0;
static constexpr size_t kPlannerDeltaQueueCapacity = 16;

struct MapDeltaEvent {
    uint64_t map_revision = 0;
    double timestamp = 0.0;
    std::vector<planning::GridCoord> changed_cells;
    std::vector<planning::GridCoord> newly_occupied_cells;
};

static std::deque<MapDeltaEvent> g_planner_delta_queue;
static bool g_planner_delta_overflowed = false;

struct LatestMapState {
    core::PoseSE3d body_to_world;
    double timestamp = 0.0;
    uint64_t revision = 0;
    bool valid = false;
};

static LatestMapState g_latest_map_state;

// IMU globals
static sensors::calibration::IMUHistoryBuffer g_imu_history;
static sensors::calibration::IMUCalibration g_imu_calib(g_imu_history);
static sensors::IMUPreintegrator g_imu_preintegrator(g_imu_calib);
static std::atomic<bool> g_imu_ready{false};

// lidar camera globals
static sensors::CameraConfig g_cam_config;
static constexpr int kLidarQueueCapacity = 4;
enum class LidarSlotState : uint8_t {
    FREE = 0,
    WRITING = 1,
    QUEUED = 2,
    READING = 3,
};
static std::array<sensors::LidarCameraData, kLidarQueueCapacity> g_lc_buffers;
static std::array<sensors::PoseLog, kLidarQueueCapacity> g_lc_pose_buffers;
static std::array<LidarSlotState, kLidarQueueCapacity> g_lc_slot_states{};
static std::array<int, kLidarQueueCapacity> g_lc_ready_queue{};
static size_t g_lc_ready_head = 0;
static size_t g_lc_ready_size = 0;
static std::atomic<bool> g_lc_ready{false};
static std::mutex g_lc_cv_mutex;
static std::condition_variable g_lc_cv;

// motor encoder odometry globals
static std::atomic<bool> g_wheel_odom_ready{false};
static std::mutex g_latest_wheel_odom_mutex;
static sensors::WheelOdometryData g_latest_wheel_odom = {0.0, -1, 0, 0, 0};
static sensors::PoseLog g_pose{-1.0, core::Vector3d{}, core::Vector4d{0.0, 0.0, 0.0, 1.0}};
static constexpr size_t kPoseHistoryCapacity = 256;
static core::RingBuffer<sensors::PoseLog, kPoseHistoryCapacity> g_pose_history;
static std::atomic<bool> g_scan_active{false};
static std::atomic<bool> g_scan_requested{false};
static std::atomic<double> g_scan_map_skip_until_timestamp{-1.0};


static void set_autonomy_substate(
    autonomy::AutonomySubstate next_state,
    const char* reason = nullptr) {
    const autonomy::AutonomySubstate previous =
        g_autonomy_substate.exchange(next_state, std::memory_order_acq_rel);
    if (previous == next_state) {
        return;
    }
    std::ostringstream log;
    log << "[autonomy][fsm] "
        << autonomy::autonomy_substate_name(previous)
        << " -> "
        << autonomy::autonomy_substate_name(next_state);
    if (reason && reason[0] != '\0') {
        log << " reason=" << reason;
    }
    wasm_log_line(log.str());
}

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

static bool read_latest_pose_snapshot(std::mutex& m_pose, sensors::PoseLog* out) {
    if (!out) {
        return false;
    }
    std::lock_guard<std::mutex> lk(m_pose);
    *out = g_pose;
    return out->timestamp > 0.0;
}

static bool pose_log_valid(const sensors::PoseLog& pose) {
    const double q_norm2 =
        pose.quaternion.x * pose.quaternion.x +
        pose.quaternion.y * pose.quaternion.y +
        pose.quaternion.z * pose.quaternion.z +
        pose.quaternion.w * pose.quaternion.w;
    return pose.timestamp > 0.0 && q_norm2 > 1e-6;
}

static void notify_planner_wake() {
    {
        std::lock_guard<std::mutex> lk(g_planner_wake_mutex);
        ++g_planner_wake_revision;
    }
    g_planner_wake_cv.notify_one();
}

static void enqueue_planner_delta_event(
    uint64_t map_revision,
    double timestamp,
    std::vector<planning::GridCoord> changed_cells,
    std::vector<planning::GridCoord> newly_occupied_cells) {
    {
        std::lock_guard<std::mutex> lk(g_planner_wake_mutex);
        if (g_planner_delta_queue.size() >= kPlannerDeltaQueueCapacity) {
            g_planner_delta_queue.pop_front();
            g_planner_delta_overflowed = true;
        }
        MapDeltaEvent event;
        event.map_revision = map_revision;
        event.timestamp = timestamp;
        event.changed_cells = std::move(changed_cells);
        event.newly_occupied_cells = std::move(newly_occupied_cells);
        g_planner_delta_queue.push_back(std::move(event));
        ++g_planner_wake_revision;
    }
    g_planner_wake_cv.notify_one();
}

static core::Vector4d quat_nlerp(
    const core::Vector4d& a,
    const core::Vector4d& b,
    double t) {
    core::Vector4d b_adjusted = b;
    const double dot =
        (a.x * b.x) + (a.y * b.y) + (a.z * b.z) + (a.w * b.w);
    if (dot < 0.0) {
        b_adjusted.x = -b_adjusted.x;
        b_adjusted.y = -b_adjusted.y;
        b_adjusted.z = -b_adjusted.z;
        b_adjusted.w = -b_adjusted.w;
    }
    const double inv_t = 1.0 - t;
    return core::quat_normalize(core::Vector4d{
        inv_t * a.x + t * b_adjusted.x,
        inv_t * a.y + t * b_adjusted.y,
        inv_t * a.z + t * b_adjusted.z,
        inv_t * a.w + t * b_adjusted.w});
}

static void record_pose_history_locked(const sensors::PoseLog& pose) {
    if (pose.timestamp <= 0.0) {
        return;
    }
    if (!g_pose_history.empty()) {
        sensors::PoseLog& back = g_pose_history.back();
        if (pose.timestamp < back.timestamp) {
            return;
        }
        if (pose.timestamp == back.timestamp) {
            back = pose;
            return;
        }
    }
    g_pose_history.push(pose);
}

static bool sample_pose_at_timestamp_locked(double timestamp, sensors::PoseLog* out) {
    if (!out || timestamp <= 0.0 || g_pose_history.empty()) {
        return false;
    }
    const size_t history_size = g_pose_history.size();
    const sensors::PoseLog& front = g_pose_history.front();
    if (timestamp <= front.timestamp || history_size == 1) {
        *out = front;
        return true;
    }
    const sensors::PoseLog& back = g_pose_history.back();
    if (timestamp >= back.timestamp) {
        *out = back;
        return true;
    }

    for (size_t i = 1; i < history_size; ++i) {
        const sensors::PoseLog& prev = g_pose_history.at(i - 1);
        const sensors::PoseLog& next = g_pose_history.at(i);
        if (timestamp > next.timestamp) {
            continue;
        }
        const double span = next.timestamp - prev.timestamp;
        if (span <= 1e-6) {
            *out = next;
            return true;
        }
        const double alpha = std::clamp((timestamp - prev.timestamp) / span, 0.0, 1.0);
        out->timestamp = timestamp;
        out->translation = core::Vector3d{
            prev.translation.x + (next.translation.x - prev.translation.x) * alpha,
            prev.translation.y + (next.translation.y - prev.translation.y) * alpha,
            prev.translation.z + (next.translation.z - prev.translation.z) * alpha};
        out->quaternion = quat_nlerp(prev.quaternion, next.quaternion, alpha);
        return true;
    }

    *out = back;
    return true;
}

static bool lidar_queue_has_free_slot_locked() {
    for (const LidarSlotState state : g_lc_slot_states) {
        if (state == LidarSlotState::FREE) {
            return true;
        }
    }
    return false;
}

static int claim_lidar_free_slot_locked() {
    for (size_t idx = 0; idx < g_lc_slot_states.size(); ++idx) {
        if (g_lc_slot_states[idx] == LidarSlotState::FREE) {
            g_lc_slot_states[idx] = LidarSlotState::WRITING;
            return static_cast<int>(idx);
        }
    }
    return -1;
}

static void push_lidar_ready_slot_locked(int slot_idx) {
    const size_t tail = (g_lc_ready_head + g_lc_ready_size) % g_lc_ready_queue.size();
    g_lc_ready_queue[tail] = slot_idx;
    ++g_lc_ready_size;
}

static int pop_lidar_ready_slot_locked() {
    if (g_lc_ready_size == 0) {
        return -1;
    }
    const int slot_idx = g_lc_ready_queue[g_lc_ready_head];
    g_lc_ready_head = (g_lc_ready_head + 1) % g_lc_ready_queue.size();
    --g_lc_ready_size;
    return slot_idx;
}

static core::PoseSE2d pose_log_to_se2(const sensors::PoseLog& pose) {
    return core::PoseSE2d{
        pose.translation.x,
        pose.translation.y,
        core::quat_to_euler_yaw(core::quat_normalize(pose.quaternion))};
}

static bool pose_to_map_cell(
    const mapping::MapSnapshot& snapshot,
    const core::PoseSE2d& pose,
    planning::GridCoord* out_cell) {
    if (!out_cell ||
        snapshot.meta.width <= 0 ||
        snapshot.meta.height <= 0 ||
        snapshot.meta.resolution_m <= 0.0) {
        return false;
    }
    const int32_t gx = static_cast<int32_t>(
        std::floor((pose.x - snapshot.meta.origin_x_m) / snapshot.meta.resolution_m));
    const int32_t gy = static_cast<int32_t>(
        std::floor((pose.y - snapshot.meta.origin_y_m) / snapshot.meta.resolution_m));
    if (gx < 0 || gx >= snapshot.meta.width || gy < 0 || gy >= snapshot.meta.height) {
        return false;
    }
    *out_cell = planning::GridCoord{gx, gy};
    return true;
}

enum class PoseSource{
    IMU,
    wheel_odom,
    fused_IMU_wheel_odom
};
// IMU preintegration drifts over time, so the shared autonomy/map pose should
// not treat it as a drop-in orientation estimate.
static constexpr PoseSource pose_source = PoseSource::fused_IMU_wheel_odom;
static constexpr bool kEnableInitialSpin = true;
static std::atomic<bool> g_initial_spin_done{!kEnableInitialSpin};
static constexpr int32_t kPathFollowHoldMs = 120;
static constexpr bool kEnableWheelPoseLogging = true;
static constexpr double kWheelPoseLogIntervalSec = 0.2;
static constexpr double kGoalCheckLogIntervalSec = 0.5;
static constexpr bool kEnableVerboseAutonomyLogs = false;
static constexpr int32_t kPlannerPollMs = 50;
static constexpr double kPlannerMinIntervalSec = 0.35;
static constexpr int32_t kTelemetryRenderIntervalMs = 33;
static constexpr double kPoseTrailMinDistanceM = 0.05;
static constexpr double kPoseTrailMinYawDeltaRad = 10.0 * core::pi / 180.0;
static constexpr double kPoseTrailMinIntervalSec = 0.05;

struct OuterLoopTurnPidConfig {
    double kp_omega_per_rad;
    double ki_omega_per_rad_s;
    double kd_omega_per_rad;
    double max_omega_rad_s;
    double min_omega_rad_s;
    double integral_limit_rad_s;
    double yaw_tolerance_rad;
};

static constexpr OuterLoopTurnPidConfig kScan4x90TurnPidCfg{
    8.0,
    0.25,
    1.0,
    0.5 * core::pi,
    0.2,
    0.6,
    1.5 * core::pi / 180.0};

static constexpr double kScan4x90FinalMinOmegaRadS = 0.05;
static constexpr double kScan4x90YawDeadzoneRad = 2.0 * core::pi / 180.0;
static constexpr double kScan4x90SettleYawRateRadS = 6.0 * core::pi / 180.0;
static constexpr int kScan4x90SettleSamplesRequired = 3;

static bool read_scan_odom_sample(sensors::WheelOdometryData* out) {
    return read_latest_wheel_odom_snapshot(out);
}

void scan_4x90(controls::MotorController& motors, std::mutex& m_pose) {
    constexpr int kSegments = 4;
    constexpr double kQuarterTurnRad = 0.5 * core::pi;
    constexpr int kTurnHoldMs = 150;
    constexpr int kPollSleepMs = 5;
    constexpr int kSegmentSettleMs = 100;
    constexpr double kScanWarmupSec = 5.0;
    constexpr int kScanWarmupSleepMs = 1000;

    sensors::WheelOdometryData odom{};
    while (!read_scan_odom_sample(&odom)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kPollSleepMs));
    }

    sensors::PoseLog pose_copy{};
    {
        std::lock_guard<std::mutex> lk(m_pose);
        pose_copy = g_pose;
    }
    double yaw = core::quat_to_euler_yaw(pose_copy.quaternion);
    int32_t last_seq = odom.seq;
    double target_yaw = yaw;

    motors.stop();
    motors.reset_twist_controller();
    wasm_log_line("[autonomy][scan] starting 4x90 scan");

    for (int segment = 0; segment < kSegments; ++segment) {
        const double segment_start_yaw = yaw;
        target_yaw += kQuarterTurnRad;
        double integral_term = 0.0;
        double prev_error = target_yaw - yaw;
        double prev_yaw = yaw;
        int settle_samples = 0;

        while (true) {
            sensors::WheelOdometryData next_odom{};
            if (!read_scan_odom_sample(&next_odom) || next_odom.seq == last_seq) {
                std::this_thread::sleep_for(std::chrono::milliseconds(kPollSleepMs));
                continue;
            }
            last_seq = next_odom.seq;
            const double dt_seconds = std::max(
                1e-3,
                static_cast<double>(std::max(1, next_odom.sample_period_ms)) * 1e-3);
            {
                std::lock_guard<std::mutex> lk(m_pose);
                pose_copy = g_pose;
            }
            const double measured_yaw = core::quat_to_euler_yaw(pose_copy.quaternion);
            yaw = core::unwrap_angle_near(measured_yaw, yaw);
            const double yaw_rate = (yaw - prev_yaw) / dt_seconds;
            prev_yaw = yaw;

            const double yaw_error = target_yaw - yaw;
            if (std::abs(yaw_error) <= kScan4x90YawDeadzoneRad) {
                motors.stop();
                motors.reset_twist_controller();
                integral_term = 0.0;
                prev_error = yaw_error;
                if (std::abs(yaw_rate) <= kScan4x90SettleYawRateRadS) {
                    if (++settle_samples >= kScan4x90SettleSamplesRequired) {
                        std::ostringstream segment_log;
                        const double turned_deg = (yaw - segment_start_yaw) * (180.0 / core::pi);
                        const double target_deg = (target_yaw - segment_start_yaw) * (180.0 / core::pi);
                        const double error_deg = yaw_error * (180.0 / core::pi);
                        // segment_log << "[autonomy][scan] phase "
                        //             << (segment + 1)
                        //             << " turned_deg=" << turned_deg
                        //             << " target_deg=" << target_deg
                        //             << " error_deg=" << error_deg;
                        // wasm_log_line(segment_log.str());
                        break;
                    }
                } else {
                    settle_samples = 0;
                }
                continue;
            }
            settle_samples = 0;

            integral_term += yaw_error * dt_seconds;
            const double max_integral_term = kScan4x90TurnPidCfg.integral_limit_rad_s /
                std::max(1e-6, kScan4x90TurnPidCfg.ki_omega_per_rad_s);
            integral_term = std::clamp(integral_term, -max_integral_term, max_integral_term);

            const double derivative = (yaw_error - prev_error) / dt_seconds;
            prev_error = yaw_error;

            double omega_cmd =
                (kScan4x90TurnPidCfg.kp_omega_per_rad * yaw_error) +
                (kScan4x90TurnPidCfg.ki_omega_per_rad_s * integral_term) +
                (kScan4x90TurnPidCfg.kd_omega_per_rad * derivative);
            omega_cmd = std::clamp(
                omega_cmd,
                -kScan4x90TurnPidCfg.max_omega_rad_s,
                kScan4x90TurnPidCfg.max_omega_rad_s);

            double min_omega = kScan4x90TurnPidCfg.min_omega_rad_s;
            if (std::abs(omega_cmd) < min_omega) {
                omega_cmd = std::copysign(min_omega, yaw_error);
            }

            motors.drive_twist(0.0, omega_cmd, next_odom, kTurnHoldMs);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(kSegmentSettleMs));
    }

    motors.stop();
    motors.reset_twist_controller();
    wasm_log_line("[autonomy][scan] completed 4x90 scan");
}

// Tiny planner demo: set a fixed map-view pixel goal at startup.
// Toggle off when using host-provided goal clicks.
static constexpr bool kEnablePlannerDemoGoal = false;
static constexpr int kPlannerDemoGoalPixelX = 160;
static constexpr int kPlannerDemoGoalPixelY = 128;
static constexpr int32_t kRenderWidth = 256;
static constexpr int32_t kRenderHeight = 256;
}; //namespace

int main(){
    std::mutex m_imu;
    std::mutex m_lc;
    std::mutex m_pose;

    controls::MotorController motors;
    motors.set_odom_reader(read_latest_wheel_odom_snapshot);
    motors.stop(); // ensure motors start from a safe state

    init_camera(&g_cam_config);
    log_config(g_cam_config);
    planning::bridge::set_goal_change_callback(notify_planner_wake);

    if (kEnablePlannerDemoGoal) {
        planning::bridge::set_goal_map_pixel(
            kPlannerDemoGoalPixelX,
            kPlannerDemoGoalPixelY);
    } else {
        planning::bridge::clear_goal();
    }

    std::thread autonomy_thread([&motors, &m_pose](){
        constexpr int kAutonomyFSMSleepMs = 100;
        constexpr double kLidarWarmupSec = 2.0;

        // the main high level thread
        while(!g_imu_ready.load(std::memory_order_acquire) ||
              !g_lc_ready.load(std::memory_order_acquire)
        ){
            std::this_thread::sleep_for(std::chrono::milliseconds(kAutonomyFSMSleepMs));
        }
        if (pose_source == PoseSource::wheel_odom || pose_source == PoseSource::fused_IMU_wheel_odom){
            while(!g_wheel_odom_ready.load(std::memory_order_acquire)){
                std::this_thread::sleep_for(std::chrono::milliseconds(kAutonomyFSMSleepMs));
            }
        }
        {
            std::ostringstream warmup_log;
            warmup_log << "[autonomy][init] lidar warmup for "
                       << kLidarWarmupSec
                       << "s";
            wasm_log_line(warmup_log.str());
        }
        std::this_thread::sleep_for(std::chrono::duration<double>(kLidarWarmupSec));
        wasm_log_line("[autonomy][init] lidar warmup complete");
        wasm_log_line("SENSOR_INIT -> AUTONOMY_INIT");
        g_state.store(RobotState::AUTONOMY_INIT, std::memory_order_release);
        while(!g_first_map_update_done.load(std::memory_order_acquire)){
            std::this_thread::sleep_for(std::chrono::milliseconds(kAutonomyFSMSleepMs));
        }

        if (!g_initial_spin_done.load(std::memory_order_acquire)) {
            set_autonomy_substate(autonomy::AutonomySubstate::SCANNING, "initial_spin");
            g_scan_active.store(true, std::memory_order_release);
            scan_4x90(motors, m_pose);
            g_scan_active.store(false, std::memory_order_release);
            g_initial_spin_done.store(true, std::memory_order_release);
            set_autonomy_substate(autonomy::AutonomySubstate::PLANNER_INIT, "initial_spin_complete");
        }

        wasm_log_line("AUTONOMY_INIT -> AUTONOMY_ENGAGED");
        g_state.store(RobotState::AUTONOMY_ENGAGED, std::memory_order_release);
        set_autonomy_substate(autonomy::AutonomySubstate::PLANNER_INIT, "autonomy_engaged");

        while (true) {
            if (g_scan_requested.exchange(false, std::memory_order_acq_rel)) {
                set_autonomy_substate(autonomy::AutonomySubstate::SCANNING, "scan_requested");
                g_scan_active.store(true, std::memory_order_release);
                scan_4x90(motors, m_pose);
                g_scan_active.store(false, std::memory_order_release);
                if (g_planner_initialized.load(std::memory_order_acquire)) {
                    set_autonomy_substate(autonomy::AutonomySubstate::WAITING_FOR_PATH, "scan_complete");
                } else {
                    set_autonomy_substate(autonomy::AutonomySubstate::PLANNER_INIT, "scan_complete_waiting_for_planner");
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(kAutonomyFSMSleepMs));
        }
    });

    std::thread imu_thread([&m_imu, &m_pose](){
        using Clock = std::chrono::steady_clock;
        const auto target_interval = std::chrono::microseconds(sensors::IMUIntervalMicrosecond);
        double g_last_logged_imu_timestamp = -1.0;
        double g_last_calib_timestamp = -1.0;

        // initial calibration for gyro and accelerometer biases
        g_imu_calib.init_biases();
        g_imu_preintegrator.reset();
        g_imu_preintegrator.update_bias();
        g_last_calib_timestamp = g_imu_calib.last_calibrated;
        g_imu_ready.store(true, std::memory_order_release);
        wasm_log_line("IMU initialized");

        static sensors::IMUData imu_copy;
        auto last_sample_time = Clock::now();
        while(true){
            {
                std::lock_guard<std::mutex> lk(m_imu);
                read_imu(&g_imu_calib.new_write_slot());
                g_imu_calib.update();
                g_imu_calib.recalibrate(); // if possible, update biases
                if (g_imu_calib.last_calibrated > g_last_calib_timestamp) {
                    g_last_calib_timestamp = g_imu_calib.last_calibrated;
                    g_imu_preintegrator.update_bias();
                }
                imu_copy = g_imu_calib.curr_slot();
                if (pose_source == PoseSource::IMU || pose_source == PoseSource::fused_IMU_wheel_odom){
                    // only update the rotation since the accelerometer drifts too much
                    sensors::PoseLog pose_copy{};
                    g_imu_preintegrator.get_pose_log(&pose_copy);
                    {
                        std::lock_guard<std::mutex> lk(m_pose);
                        g_pose.quaternion = pose_copy.quaternion;
                        if (pose_source == PoseSource::IMU) {
                            g_pose.timestamp = pose_copy.timestamp;
                        }
                        pose_copy = g_pose;
                    }
                    rerun_log_pose(&pose_copy);
                }
                // wasm_log_line("imu: " + std::to_string(imu_copy.timestamp) + ", " + std::to_string(imu_copy.gyro_z));
            }
            g_imu_preintegrator.integrate(imu_copy);
            const auto curr_time = Clock::now();
            const auto elapsed = curr_time - last_sample_time;
            if (elapsed < target_interval) {
                std::this_thread::sleep_for(target_interval - elapsed);
            }
            last_sample_time = Clock::now();
        }
    });
    std::thread lidar_camera_thread([&m_lc, &m_pose](){
        double last_lidar_log_timestamp = -1.0;

        while(true){
            int write_idx = -1;
            {
                std::unique_lock<std::mutex> lk(g_lc_cv_mutex);
                g_lc_cv.wait(lk, [&]{
                    return lidar_queue_has_free_slot_locked();
                });
                write_idx = claim_lidar_free_slot_locked();
            }
            if (write_idx < 0) {
                continue;
            }

            g_lc_buffers[write_idx].timestamp = 0.0;
            g_lc_buffers[write_idx].points_size = 0;
            g_lc_buffers[write_idx].colors_size = 0;
            g_lc_buffers[write_idx].image_size = 0;
            read_lidar_camera(&g_lc_buffers[write_idx]);
            sensors::ensure_points_flu(g_lc_buffers[write_idx]);
            {
                std::lock_guard<std::mutex> lk(m_pose);
                if (!sample_pose_at_timestamp_locked(
                        g_lc_buffers[write_idx].timestamp,
                        &g_lc_pose_buffers[write_idx])) {
                    g_lc_pose_buffers[write_idx] = g_pose;
                }
            }
            if (!pose_log_valid(g_lc_pose_buffers[write_idx])) {
                g_lc_pose_buffers[write_idx].timestamp = -1.0;
            }

            if (g_lc_buffers[write_idx].points_size > 0) {
                if (g_lc_buffers[write_idx].timestamp > 0.0 &&
                    (last_lidar_log_timestamp < 0.0 ||
                     (g_lc_buffers[write_idx].timestamp - last_lidar_log_timestamp) >=
                         kLidarLogIntervalSec)) {
                    rerun_log_lidar_frame(&g_lc_buffers[write_idx]);
                    last_lidar_log_timestamp = g_lc_buffers[write_idx].timestamp;
                }

                // Timestamp deduplication is intentionally omitted here. Mapping only
                // requires monotonically advancing timestamps, and deduplicating at the
                // producer caused a permanent stall whenever the host returned the same
                // timestamp on consecutive calls.
                if (!g_lc_ready.load(std::memory_order_relaxed)) {
                    g_lc_ready.store(true, std::memory_order_release);
                    wasm_log_line("Lidar camera initialized");
                }
                {
                    std::lock_guard<std::mutex> lk(g_lc_cv_mutex);
                    g_lc_slot_states[write_idx] = LidarSlotState::QUEUED;
                    push_lidar_ready_slot_locked(write_idx);
                }
                g_lc_cv.notify_one();
                // wasm_log_line("lidar: " + std::to_string(g_lc_buffers[write_idx].timestamp) + ", " + std::to_string(g_lc_buffers[write_idx].points_size));
            } else {
                {
                    std::lock_guard<std::mutex> lk(g_lc_cv_mutex);
                    g_lc_slot_states[write_idx] = LidarSlotState::FREE;
                }
                g_lc_cv.notify_one();
            }
        }
    });


    std::thread mapping_thread([&m_pose](){
      double last_map_timestamp = -1.0;

      RobotState state;
      do{
        state = g_state.load(std::memory_order_acquire);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      } while (state != RobotState::AUTONOMY_ENGAGED && state != RobotState::AUTONOMY_INIT);

      if (pose_source == PoseSource::fused_IMU_wheel_odom || pose_source == PoseSource::wheel_odom){
        while(!g_wheel_odom_ready.load(std::memory_order_acquire)){
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
      }

      {
        std::lock_guard<std::mutex> lk(g_map_mutex);
        mapping::initialize_map(g_map);
        g_latest_map_state = LatestMapState{};
      }
      wasm_log_line("Map initialized");

      while(true){

        // get a valid lidar-camera frame, then get the most recent pose
        int ready_idx = -1;
        {
            std::unique_lock<std::mutex> lk(g_lc_cv_mutex);
            g_lc_cv.wait(lk, []{return g_lc_ready_size > 0;});
            ready_idx = pop_lidar_ready_slot_locked();
            if (ready_idx >= 0) {
                g_lc_slot_states[ready_idx] = LidarSlotState::READING;
            }
        }
        if (ready_idx < 0) {
            std::this_thread::yield();
            continue;
        }
        const sensors::LidarCameraData& lc_data = g_lc_buffers[ready_idx];
        const sensors::PoseLog& pose_snapshot = g_lc_pose_buffers[ready_idx];
        if (lc_data.points_size <= 0) {
            {
                std::lock_guard<std::mutex> lk(g_lc_cv_mutex);
                g_lc_slot_states[ready_idx] = LidarSlotState::FREE;
            }
            g_lc_cv.notify_one();
            std::this_thread::yield();
            continue;
        }
        if (!pose_log_valid(pose_snapshot)) {
            static bool warned_about_invalid_pose = false;
            if (!warned_about_invalid_pose) {
                wasm_log_line("[mapping] skipping lidar frame until pose is initialized");
                warned_about_invalid_pose = true;
            }
            {
                std::lock_guard<std::mutex> lk(g_lc_cv_mutex);
                g_lc_slot_states[ready_idx] = LidarSlotState::FREE;
            }
            g_lc_cv.notify_one();
            continue;
        }
        core::PoseSE3d body_to_world;
        body_to_world.quaternion = pose_snapshot.quaternion;
        body_to_world.translation = pose_snapshot.translation;
        const double pose_timestamp = pose_snapshot.timestamp;
        const double candidate_timestamp = std::max(lc_data.timestamp, pose_timestamp);
        if (candidate_timestamp <= 0.0 ||
            (last_map_timestamp > 0.0 && candidate_timestamp <= last_map_timestamp)) {
            {
                std::lock_guard<std::mutex> lk(g_lc_cv_mutex);
                g_lc_slot_states[ready_idx] = LidarSlotState::FREE;
            }
            g_lc_cv.notify_one();
            continue;
        }
        uint64_t map_revision = 0;
        std::vector<planning::GridCoord> changed_cells;
        std::vector<planning::GridCoord> newly_occupied_cells;
        {
            std::lock_guard<std::mutex> lk(g_map_mutex);
            // project the filtered lidar scan into the occupancy grid.
            mapping::update_map_from_lidar(
                g_map,
                lc_data,
                body_to_world,
                &changed_cells,
                &newly_occupied_cells
            );
            map_revision =
                g_map_update_revision.fetch_add(1, std::memory_order_acq_rel) + 1;
            g_latest_map_state.body_to_world = body_to_world;
            g_latest_map_state.timestamp = candidate_timestamp;
            g_latest_map_state.revision = map_revision;
            g_latest_map_state.valid = true;
            mapping::MapSnapshot snapshot;
            if (mapping::build_map_snapshot(
                    g_map,
                    body_to_world,
                    candidate_timestamp,
                    map_revision,
                    &snapshot)) {
                std::lock_guard<std::mutex> publish_lk(g_map_publish_mutex);
                g_latest_map_snapshot = std::move(snapshot);
            }
        }
        if (!g_first_map_update_done.load(std::memory_order_relaxed)) {
            g_first_map_update_done.store(true, std::memory_order_release);
        }
        last_map_timestamp = candidate_timestamp;
        enqueue_planner_delta_event(
            map_revision,
            candidate_timestamp,
            std::move(changed_cells),
            std::move(newly_occupied_cells));

        // wasm_log_line("map_time: " + std::to_string(last_map_timestamp));

        {
            std::lock_guard<std::mutex> lk(g_lc_cv_mutex);
            g_lc_slot_states[ready_idx] = LidarSlotState::FREE;
        }
        g_lc_cv.notify_one();
      }
    });

    // only runs after a map update has occurred
    std::thread planner_thread([&m_pose](){
        RobotState state;
        do{
            state = g_state.load(std::memory_order_acquire);
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        } while (state != RobotState::AUTONOMY_ENGAGED);

        wasm_log_line("Planner initialized");
        g_planner_initialized.store(true, std::memory_order_release);
        set_autonomy_substate(autonomy::AutonomySubstate::WAITING_FOR_PATH, "planner_initialized");
        uint64_t last_planned_revision = 0;
        uint64_t last_goal_revision = planning::bridge::latest_goal_revision();
        planning::GridCoord last_start_cell{};
        bool have_last_start_cell = false;
        uint64_t observed_wake_revision = 0;
        std::vector<MapDeltaEvent> pending_delta_events;
        std::vector<planning::GridCoord> merged_newly_occupied_cells;
        bool delta_overflowed = false;

        while(true){
            // wait until a new map arrives, otherwise the previous plan is the best path
            {
                std::unique_lock<std::mutex> lk(g_planner_wake_mutex);
                g_planner_wake_cv.wait(lk, [&]{
                    return g_planner_wake_revision != observed_wake_revision ||
                           !g_planner_delta_queue.empty();
                });
                observed_wake_revision = g_planner_wake_revision;
                pending_delta_events.clear();
                while (!g_planner_delta_queue.empty()) {
                    pending_delta_events.push_back(std::move(g_planner_delta_queue.front()));
                    g_planner_delta_queue.pop_front();
                }
                delta_overflowed = g_planner_delta_overflowed;
                g_planner_delta_overflowed = false;
            }

            mapping::MapSnapshot snapshot;
            planning::bridge::PlanningOverlay current_overlay;
            {
                std::lock_guard<std::mutex> lk(g_map_publish_mutex);
                snapshot = g_latest_map_snapshot;
            }
            {
                std::lock_guard<std::mutex> lk(g_plan_publish_mutex);
                current_overlay = g_latest_plan_overlay;
            }
            if (!snapshot.valid()) {
                wasm_log_line("snapshot invalid");
                continue;
            }


            sensors::PoseLog pose_snapshot{};
            if (read_latest_pose_snapshot(m_pose, &pose_snapshot)) {
                wasm_log_line("reading pose snapshot");
                snapshot.pose = pose_log_to_se2(pose_snapshot);
                snapshot.timestamp = std::max(snapshot.timestamp, pose_snapshot.timestamp);
            }

            const uint64_t goal_revision = planning::bridge::latest_goal_revision();
            planning::GridCoord start_cell{};
            const bool have_start_cell = pose_to_map_cell(snapshot, snapshot.pose, &start_cell);
            const bool start_cell_changed =
                have_start_cell &&
                (!have_last_start_cell || !(start_cell == last_start_cell));
            const bool map_changed = snapshot.map_revision != last_planned_revision;
            const bool goal_changed = goal_revision != last_goal_revision;
            merged_newly_occupied_cells.clear();
            if (!pending_delta_events.empty()) {
                size_t total_newly_occupied = 0;
                for (const MapDeltaEvent& event : pending_delta_events) {
                    total_newly_occupied += event.newly_occupied_cells.size();
                }
                merged_newly_occupied_cells.reserve(total_newly_occupied);
                for (const MapDeltaEvent& event : pending_delta_events) {
                    merged_newly_occupied_cells.insert(
                        merged_newly_occupied_cells.end(),
                        event.newly_occupied_cells.begin(),
                        event.newly_occupied_cells.end());
                }
            } else {
                merged_newly_occupied_cells.clear();
            }
            const bool have_active_overlay_path =
                current_overlay.source_map_revision > 0 &&
                !current_overlay.path_grid.empty();
            const bool new_occupancy_hits_path =
                !goal_changed &&
                !start_cell_changed &&
                map_changed &&
                !delta_overflowed &&
                have_active_overlay_path &&
                planning::bridge::does_new_occupancy_intersect_overlay_path(
                    snapshot,
                    current_overlay,
                    merged_newly_occupied_cells);
            std::ostringstream trigger_log;
            trigger_log << "[planner][trigger] wake_revision=" << observed_wake_revision
                        << " map_revision=" << snapshot.map_revision
                        << " last_planned_revision=" << last_planned_revision
                        << " goal_revision=" << goal_revision
                        << " last_goal_revision=" << last_goal_revision
                        << " have_start_cell=" << (have_start_cell ? 1 : 0)
                        << " start_cell=(" << start_cell.x << "," << start_cell.y << ")"
                        << " have_last_start_cell=" << (have_last_start_cell ? 1 : 0)
                        << " last_start_cell=(" << last_start_cell.x << "," << last_start_cell.y << ")"
                        << " map_changed=" << (map_changed ? 1 : 0)
                        << " goal_changed=" << (goal_changed ? 1 : 0)
                        << " start_cell_changed=" << (start_cell_changed ? 1 : 0)
                        << " have_active_overlay_path=" << (have_active_overlay_path ? 1 : 0)
                        << " delta_events=" << pending_delta_events.size()
                        << " delta_overflowed=" << (delta_overflowed ? 1 : 0)
                        << " new_occupancy_hits_path=" << (new_occupancy_hits_path ? 1 : 0)
                        << " newly_occupied_count=" << merged_newly_occupied_cells.size()
                        << " snapshot_timestamp=" << snapshot.timestamp
                        << " pose_timestamp=" << pose_snapshot.timestamp;
            wasm_log_line(trigger_log.str());
            // Skip case 1: nothing has changed and no valid plan exists yet — wait for
            // the first real trigger (goal set, map update, or robot moves a cell).
            if (!goal_changed &&
                !last_planned_revision &&
                !map_changed &&
                !start_cell_changed) {
                wasm_log_line("case 1: no changes and no valid plan");
                continue;
            }
            // Skip case 2: a valid plan already exists and nothing relevant has changed —
            // the current path is still good, no replan needed.
            if (!goal_changed &&
                last_planned_revision > 0 &&
                !map_changed &&
                !start_cell_changed) {
                wasm_log_line("case 2: valid plan and path is good");
                continue;
            }
            if (map_changed &&
                !goal_changed &&
                !start_cell_changed &&
                have_active_overlay_path &&
                !delta_overflowed &&
                !new_occupancy_hits_path) {
                wasm_log_line("case 3: map delta misses inflated path corridor");
                last_planned_revision = snapshot.map_revision;
                continue;
            }
            // No case-3 rate-limiter: D* Lite only re-expands cells near changed
            // obstacles, so replanning on every new scan is cheap.

            wasm_log_line("redrawing planning overlay");
            if (goal_changed) {
                set_autonomy_substate(autonomy::AutonomySubstate::GOAL_SELECTION, "goal_changed");
            } else {
                set_autonomy_substate(autonomy::AutonomySubstate::FRONTIER_DETECTION, "planner_wake");
                set_autonomy_substate(autonomy::AutonomySubstate::GOAL_SELECTION, "auto_frontier_goal");
            }
            set_autonomy_substate(autonomy::AutonomySubstate::PLANNING_GOAL, "update_plan_overlay");
            planning::bridge::PlanningOverlay overlay =
                planning::bridge::update_plan_overlay(
                    snapshot,
                    kRenderWidth,
                    kRenderHeight);
            const bool published_path = !overlay.path_grid.empty();
            last_planned_revision = snapshot.map_revision;
            last_goal_revision = goal_revision;
            if (have_start_cell) {
                last_start_cell = start_cell;
                have_last_start_cell = true;
            }
            {
                std::lock_guard<std::mutex> lk(g_plan_publish_mutex);
                g_latest_plan_overlay = std::move(overlay);
            }
            if (!published_path) {
                set_autonomy_substate(autonomy::AutonomySubstate::NO_PATH_AVAILABLE, "planner_produced_no_path");
                if (!goal_changed &&
                    g_planner_initialized.load(std::memory_order_acquire) &&
                    !g_scan_requested.load(std::memory_order_acquire) &&
                    !g_scan_active.load(std::memory_order_acquire)) {
                    set_autonomy_substate(autonomy::AutonomySubstate::SCAN_REQUESTED, "planner_requested_scan");
                    g_scan_requested.store(true, std::memory_order_release);
                } else {
                    set_autonomy_substate(autonomy::AutonomySubstate::WAITING_FOR_PATH, "planner_produced_no_path_wait");
                }
            } else {
                set_autonomy_substate(autonomy::AutonomySubstate::FOLLOWING_PATH, "planner_published_path");
            }
        }


    });


    std::thread telemetry_thread([&m_pose](){
        mapping::PoseTrailState pose_trail;
        uint64_t last_rendered_map_revision = 0;
        uint64_t last_rendered_path_revision = 0;
        double last_rendered_pose_timestamp = -1.0;
        double last_pose_trail_timestamp = -1.0;
        core::PoseSE2d last_trail_pose{};
        bool have_last_trail_pose = false;
        while (true) {
            mapping::MapSnapshot snapshot;
            planning::bridge::PlanningOverlay overlay;
            {
                std::lock_guard<std::mutex> lk(g_map_publish_mutex);
                snapshot = g_latest_map_snapshot;
            }
            {
                std::lock_guard<std::mutex> lk(g_plan_publish_mutex);
                overlay = g_latest_plan_overlay;
            }
            if (!snapshot.valid()) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(kTelemetryRenderIntervalMs));
                continue;
            }

            sensors::PoseLog pose_snapshot{};
            if (!read_latest_pose_snapshot(m_pose, &pose_snapshot)) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(kTelemetryRenderIntervalMs));
                continue;
            }
            snapshot.pose = pose_log_to_se2(pose_snapshot);
            snapshot.timestamp = std::max(snapshot.timestamp, pose_snapshot.timestamp);

            const uint64_t path_revision = planning::bridge::copy_latest_plan_world(nullptr);
            const bool map_changed = snapshot.map_revision != last_rendered_map_revision;
            const bool path_changed = path_revision != last_rendered_path_revision;
            const bool pose_changed = pose_snapshot.timestamp > last_rendered_pose_timestamp;
            if (!map_changed && !path_changed && !pose_changed) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(kTelemetryRenderIntervalMs));
                continue;
            }

            const bool time_gate =
                (last_pose_trail_timestamp < 0.0) ||
                ((pose_snapshot.timestamp - last_pose_trail_timestamp) >=
                 kPoseTrailMinIntervalSec);
            const double dx = snapshot.pose.x - last_trail_pose.x;
            const double dy = snapshot.pose.y - last_trail_pose.y;
            const double dist = std::sqrt(dx * dx + dy * dy);
            const double dyaw = have_last_trail_pose
                ? std::abs(core::normalize_angle(snapshot.pose.theta - last_trail_pose.theta))
                : std::numeric_limits<double>::infinity();
            if (time_gate &&
                (!have_last_trail_pose ||
                 dist >= kPoseTrailMinDistanceM ||
                 dyaw >= kPoseTrailMinYawDeltaRad)) {
                if (pose_trail.poses.size() >=
                    static_cast<size_t>(mapping::kMaxPoseTrailPoints)) {
                    pose_trail.poses.erase(pose_trail.poses.begin());
                }
                pose_trail.poses.push_back(snapshot.pose);
                last_trail_pose = snapshot.pose;
                last_pose_trail_timestamp = pose_snapshot.timestamp;
                have_last_trail_pose = true;
            }
            mapping::visualization::render_map_frame(
                snapshot,
                pose_trail,
                overlay,
                kRenderWidth,
                kRenderHeight,
                g_map_image);
            last_rendered_map_revision = snapshot.map_revision;
            last_rendered_path_revision = path_revision;
            last_rendered_pose_timestamp = pose_snapshot.timestamp;
            std::this_thread::sleep_for(
                std::chrono::milliseconds(kTelemetryRenderIntervalMs));
        }
    });

    std::thread control_thread([&m_pose, &motors](){
        // responsible for reading encoder values and sending motor commands
        sensors::WheelOdometryData odom{};
        controls::PathFollower path_follower;
        std::vector<core::Vector3d> planned_path_world;
        uint64_t planned_path_revision = 0;
        core::PoseSE2d wheel_pose{};
        double last_wheel_pose_log_timestamp = -1.0;
        double last_goal_check_log_timestamp = -1.0;
        bool goal_reached_logged = false;

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

            if (pose_source == PoseSource::fused_IMU_wheel_odom) {
                core::Vector4d imu_quat_copy;
                {
                    std::lock_guard<std::mutex> lk(m_pose);
                    imu_quat_copy = g_pose.quaternion;
                }
                const double imu_yaw = core::quat_to_euler_yaw(
                        core::quat_normalize(imu_quat_copy));
                // In fused mode, wheel odometry contributes distance while IMU yaw
                // is used continuously as the robot heading.
                sensors::integrate_wheel_odometry(odom, imu_yaw, wheel_pose);
            } else {
                sensors::integrate_wheel_odometry(odom, wheel_pose);
            }
            const core::Vector3d wheel_translation{wheel_pose.x, wheel_pose.y, 0.0};

            sensors::PoseLog pose_copy{};
            if (pose_source == PoseSource::wheel_odom || pose_source == PoseSource::fused_IMU_wheel_odom) {
                std::lock_guard<std::mutex> lk(m_pose);
                g_pose.timestamp = odom.timestamp;
                g_pose.translation = wheel_translation;
                if (pose_source == PoseSource::wheel_odom) {
                    const core::Vector4d wheel_quaternion{
                        0.0, 0.0, std::sin(wheel_pose.theta * 0.5), std::cos(wheel_pose.theta * 0.5)};
                    g_pose.quaternion = wheel_quaternion;
                }
                pose_copy = g_pose;
                record_pose_history_locked(pose_copy);
            } else {
                std::lock_guard<std::mutex> lk(m_pose);
                pose_copy = g_pose;
            }

            if (kEnableWheelPoseLogging &&
                (last_wheel_pose_log_timestamp < 0.0 ||
                 (odom.timestamp - last_wheel_pose_log_timestamp) >= kWheelPoseLogIntervalSec)) {
                // rerun_log_pose_wheel(&pose_copy);
                last_wheel_pose_log_timestamp = odom.timestamp;
            }

            const RobotState state = g_state.load(std::memory_order_acquire);
            if (state != RobotState::AUTONOMY_ENGAGED) {
                continue;
            }
            if (g_scan_active.load(std::memory_order_acquire)) {
                continue;
            }

            const uint64_t latest_path_revision =
                planning::bridge::copy_latest_plan_world(&planned_path_world);
            if (latest_path_revision != planned_path_revision) {
                planned_path_revision = latest_path_revision;
                goal_reached_logged = false;
                if (!planned_path_world.empty()) {
                    path_follower.set_path(planned_path_world);
                    set_autonomy_substate(autonomy::AutonomySubstate::FOLLOWING_PATH, "control_loaded_path");
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
                    set_autonomy_substate(autonomy::AutonomySubstate::WAITING_FOR_PATH, "path_revision_cleared");
                }
            }

            if (!path_follower.has_path()) {
                motors.stop();
                continue;
            }

            const controls::Pose2D fused_pose{
                pose_copy.translation.x,
                pose_copy.translation.y,
                core::quat_to_euler_yaw(pose_copy.quaternion)};
            const double dt_seconds = std::max(
                1e-3,
                static_cast<double>(std::max(1, odom.sample_period_ms)) * 1e-3);
            const controls::PathFollowerStatus status =
                path_follower.update(fused_pose, dt_seconds, kPathFollowHoldMs);
            if (!planned_path_world.empty() &&
                (last_goal_check_log_timestamp < 0.0 ||
                 (odom.timestamp - last_goal_check_log_timestamp) >=
                     kGoalCheckLogIntervalSec)) {
                const core::Vector3d& goal = planned_path_world.back();
                const double goal_dist = std::hypot(
                    goal.x - fused_pose.x,
                    goal.y - fused_pose.y);
                double goal_heading_error = 0.0;
                if (planned_path_world.size() >= 2) {
                    const core::Vector3d& prev = planned_path_world[planned_path_world.size() - 2];
                    const double goal_heading = std::atan2(goal.y - prev.y, goal.x - prev.x);
                    goal_heading_error = core::normalize_angle(goal_heading - fused_pose.yaw);
                }
                std::ostringstream goal_log;
                goal_log << "[autonomy][goal-check] pose=("
                         << fused_pose.x << "," << fused_pose.y << "," << fused_pose.yaw
                         << ") goal=(" << goal.x << "," << goal.y
                         << ") goal_dist=" << goal_dist
                         << " goal_heading_error=" << goal_heading_error
                         << " dist_tol=0.05 heading_gate=ignored"
                         << " target_index=" << status.target_index
                         << " status_dist_error=" << status.distance_error_m
                         << " status_heading_error=" << status.heading_error_rad;
                wasm_log_line(goal_log.str());
                last_goal_check_log_timestamp = odom.timestamp;
            }
            if (status.goal_reached) {
                if (!goal_reached_logged) {
                    goal_reached_logged = true;
                    wasm_log_line("[autonomy][path] goal reached");
                }
                path_follower.clear_path();
                planning::bridge::invalidate_current_plan();
                {
                    std::lock_guard<std::mutex> lk(g_plan_publish_mutex);
                    g_latest_plan_overlay = planning::bridge::PlanningOverlay{};
                }
                motors.stop();
                set_autonomy_substate(autonomy::AutonomySubstate::SCAN_REQUESTED, "goal_reached");
                g_scan_requested.store(true, std::memory_order_release);
                continue;
            }
            goal_reached_logged = false;
            motors.drive_twist(status.command, odom);
        }
    });



    // TODO: remove once autonomy control loop is closed
    // controls::drive_forward_demo();
    // controls::drive_twist_demo(motors);

    imu_thread.join();
    lidar_camera_thread.join();
    mapping_thread.join();
    planner_thread.join();
    telemetry_thread.join();
    control_thread.join();
}
