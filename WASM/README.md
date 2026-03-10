# WASM — Roamr On-Robot SLAM & Autonomy Stack

This directory contains the entire C++ codebase that runs **inside a WebAssembly (WASM) sandbox** on the robot's iOS host device. It is compiled to `wasm32-wasip1-threads` and executed by the WAMR (WebAssembly Micro-Runtime) engine embedded in the iOS app. The WASM module communicates with the host (Swift / iOS) exclusively through **imported** host functions (sensor reads, motor writes, telemetry logging) and **exported** C functions (planner goal APIs).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Build](#build)
3. [Entry Point — slam\_main.cpp](#entry-point--slam_maincpp)
4. [Core Utilities (core/)](#core-utilities-core)
5. [Sensors (sensors/)](#sensors-sensors)
6. [Mapping (mapping/)](#mapping-mapping)
7. [Planning (planning/)](#planning-planning)
8. [Controls (controls/)](#controls-controls)
9. [Thread Model & Data Flow](#thread-model--data-flow)
10. [State Machine](#state-machine)
11. [Configuration Constants](#configuration-constants)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  iOS Host (Swift)                                                │
│  ┌───────────┐ ┌──────────────┐ ┌──────────────┐ ┌────────────┐ │
│  │ BLE/HW    │ │ LiDAR Camera │ │ IMU (CoreMo.)│ │ Rerun WS   │ │
│  │ Motors    │ │ (ARKit)      │ │              │ │ Telemetry  │ │
│  └─────┬─────┘ └──────┬───────┘ └──────┬───────┘ └─────┬──────┘ │
│        │ write_motors  │ read_lidar_cam │ read_imu      │ rerun_ │
│        │               │               │               │ log_*  │
├────────▼───────────────▼───────────────▼───────────────▼────────┤
│  WASM Module (this directory)                                    │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐            │
│  │ Controls │ │ Sensors  │ │ Mapping  │ │ Planning │            │
│  │ motors   │ │ imu/odom │ │ map/cost │ │ A*/front │            │
│  │ path fol │ │ lidar    │ │ map_upd  │ │ planner  │            │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘            │
│                       slam_main.cpp                              │
│               (5 threads, state machine)                         │
└──────────────────────────────────────────────────────────────────┘
```

The WASM module **does not** link against any OS libraries. All I/O happens through host-imported functions declared with `WASM_IMPORT(...)`. The module exports a standard `main()` entry point plus two C-linkage functions for the host UI to set/clear planner goals.

---

## Build

Requires Docker. A single script cross-compiles all source files to a threaded WASI target:

```sh
./build_wasm.sh
```

Under the hood it runs:

```
docker run ... ghcr.io/webassembly/wasi-sdk /opt/wasi-sdk/bin/clang++ \
  --target=wasm32-wasip1-threads -pthread -fno-exceptions -fno-rtti \
  -Wl,--import-memory -Wl,--export-memory -Wl,--shared-memory \
  -Wl,--max-memory=67108864 \
  slam_main.cpp core/telemetry.cpp mapping/map.cpp mapping/map_update.cpp \
  planning/frontier_explorer.cpp planning/planner_bridge.cpp \
  sensors/imu_calibration.cpp sensors/imu_preintegration.cpp
```

Key flags:
| Flag | Purpose |
|---|---|
| `--target=wasm32-wasip1-threads` | WASI preview-1 with pthreads support |
| `-fno-exceptions -fno-rtti` | Reduces binary size; no C++ exceptions in WASM |
| `--shared-memory --import-memory` | Host allocates linear memory shared across threads |
| `--max-memory=67108864` | 64 MB max heap (needed for LiDAR point buffers) |

Output: **`slam_main.wasm`**

---

## Entry Point — `slam_main.cpp`

The `main()` function bootstraps the entire system:

1. Initializes the motor controller to a safe stopped state.
2. Initializes the camera configuration via the host (`init_camera`).
3. Optionally sets a demo planner goal pixel.
4. Spawns **5 long-lived threads** (see [Thread Model](#thread-model--data-flow)).
5. Joins all threads (they run indefinitely).

### Global State

| Variable | Type | Purpose |
|---|---|---|
| `g_state` | `atomic<RobotState>` | Top-level state machine (`SENSOR_INIT → AUTONOMY_INIT → AUTONOMY_ENGAGED`) |
| `g_map_frame` | `MapFrame` | Metadata for the latest rendered occupancy map image |
| `g_map_update_revision` | `atomic<uint64_t>` | Monotonic counter incremented each time the map integrates a new scan |
| `g_lc_buffers[2]` | `LidarCameraData[2]` | Double-buffered LiDAR point cloud + camera image |
| `g_lc_ready_idx` / `g_lc_in_use_idx` | `atomic<int>` | Lock-free producer/consumer indices for the double buffer |
| `g_imu_history` | `RingBuffer<IMUData, 100>` | Rolling window of IMU samples for calibration |
| `g_imu_calib` | `IMUCalibration` | Bias estimation from still-detection |
| `g_imu_preintegrator` | `IMUPreintegrator` | Orientation integration from gyroscope |
| `g_pose` | `PoseLog` | Shared (x, y, yaw) robot pose in world frame (mutex-protected) |

---

## Core Utilities (`core/`)

### `math_utils.h`
Foundational 3D math with no external dependencies:
- **`Vector3d`** / **`Vector4d`** — 3D vector and quaternion types with arithmetic operators.
- **`Mat3d`** — Row-major 3×3 matrix as `std::array<double, 9>`.
- Quaternion operations: `quat_identity`, `quat_mul`, `quat_normalize`, `quat_conj`, `quat_from_rotvec`, `quat_from_euler_zyx`, `quat_to_euler_zyx`, `quat_rotate`.
- Vector operations: `dot`, `cross`, `norm`, `hat` (skew-symmetric matrix).
- Angle utilities: `normalize_angle` (wrap to ±π), `unwrap_angle_near` (unwrap relative to a reference).

### `coordinate_frames.h`
- Defines the two coordinate frame conventions used across the stack:
  - **RDF** (Right-Down-Forward) — native camera frame from ARKit.
  - **FLU** (Forward-Left-Up) — the body/robotics convention used internally.
- Provides `rdf_to_flu()` conversion helpers.
- **`PoseSE3d`** — SE(3) pose struct containing translation, quaternion, and frame ID.
- **`exp_SO3d`** — Rodrigues rotation formula mapping a rotation vector to a rotation matrix.

### `ring_buffer.h`
A fixed-capacity, stack-allocated circular buffer (`core::RingBuffer<T, N>`). Used for the IMU calibration history window. Supports:
- `push()` / `push_slot()` — append or get a writable reference, automatically evicting the oldest element when full.
- `front()`, `back()`, `at(i)` — indexed access.
- `emplace(...)` — in-place construction.

### `wasm_utils.h`
A single macro `WASM_IMPORT(module, name)` that annotates function declarations with the Clang WASM import attributes. All host-provided functions are declared using this macro.

### `telemetry.h` / `telemetry.cpp`
Bridge between the WASM module and the host's Rerun visualization / UI console:
- **Host-imported functions**: `rerun_log_lidar_frame`, `rerun_log_imu`, `rerun_log_pose`, `rerun_log_pose_wheel`, `wasm_log_text`.
- **`wasm_log_line(text)`** — packs a C string into a `WasmTextLog` struct (max 255 bytes) and sends it to the host's on-screen console.
- **`log_imu(...)`** — rate-limited IMU sample logger to Rerun.
- **`log_config(...)`** — one-time sensor configuration announcement.

---

## Sensors (`sensors/`)

### `imu.h`
- **`IMUData`** — timestamp, 3-axis accelerometer, 3-axis gyroscope, frame ID.
- **`read_imu(IMUData*)`** — host-imported function; fills the struct from CoreMotion.
- Refresh rate: 100 Hz (poll interval ≈ 5 ms).

### `calibration.h` / `imu_calibration.cpp`
Stationary (zero-velocity) IMU calibration:
- **`IMUCalibration`** class wraps a `RingBuffer<IMUData, 100>` history.
- **`init_biases()`** — blocking startup routine. Continuously reads IMU samples until 100 consecutive still samples are collected (accelerometer magnitude within ±0.6 m/s² of 9.81, gyro magnitude < 0.05 rad/s). Computes initial gravity vector direction and gyro/accel biases.
- **`update()`** — called per sample; increments the still-sample counter or resets it if motion is detected.
- **`recalibrate()`** — if ≥100 still samples have been accumulated since the last calibration (and ≥1 s has elapsed), re-estimates biases. This allows drift correction when the robot is stationary.

### `imu_preintegration.h` / `imu_preintegration.cpp`
Discrete-time IMU preintegration (orientation-only, translation accumulation currently disabled):
- **`IMUPreintegrator`** class holds a `PoseSE3d` pose, velocity, biases, and gravity.
- **`init_from_calibration()`** — copies current bias/gravity estimates from the calibration module.
- **`integrate(imu)`** — per-sample integration:
  1. Computes bias-corrected gyro `w` and accel `a`.
  2. Integrates rotation: `q ← q ⊗ quat_from_rotvec(w·dt)`.
  3. Accumulates `gyro_yaw_ += w.z · dt` as a diagnostic yaw signal.
  4. Rotates accelerometer into world frame, subtracts gravity, integrates velocity.
  5. Translation update is intentionally commented out (IMU drift makes it unreliable).
- **Note**: The gyro yaw is tracked but **not** used as the shared pose — wheel odometry yaw is used instead because preintegration drifts over time.

### `lidar_camera.h`
- **`CameraConfig`** — image resolution metadata, initialized by the host at startup.
- **`LidarCameraData`** — the main sensor frame struct containing:
  - Up to 100,000 3D points (`float[300000]`).
  - Per-point RGB colors.
  - Camera image (up to 1920×1440×3).
  - Frame IDs for points and image.
- **`ensure_points_flu()`** — in-place RDF→FLU coordinate conversion for the entire point cloud.
- **`read_lidar_camera(LidarCameraData*)`** — host-imported; fills from ARKit depth + camera.
- Refresh rate: 30 Hz.

### `wheel_odometry.h`
- **`WheelOdometryData`** — timestamp, sequence number, left/right tick deltas, sample period.
- **`read_wheel_odometry(WheelOdometryData*)`** — host-imported; pops the latest BLE wheel encoder sample.
- Physical constants:
  - Ticks per revolution: 16,384 (14-bit encoder)
  - Wheel radius: 25 mm
  - Wheel base: 155 mm
- **`wheel_delta_meters_from_ticks()`** — converts tick deltas to metric displacements.
- **`wheel_speed_from_odometry()`** — computes instantaneous left/right wheel speeds (m/s).
- **`integrate_wheel_odometry()`** — differential drive dead-reckoning:
  - `ds = 0.5 * (dl + dr)` — forward displacement.
  - `dθ = (dr - dl) / wheel_base` — heading change.
  - Mid-point integration: `x += ds·cos(yaw + dθ/2)`, `y += ds·sin(yaw + dθ/2)`.

---

## Mapping (`mapping/`)

### `map_api.h`
C-linkage API surface between the mapping renderer (`map.cpp`) and the rest of the stack:
- **`MapFrame`** — metadata for a rendered RGBA map image (dimensions, data pointer, byte size). The host reads pixels directly from WASM linear memory.
- **`OccupancyGridMeta`** — occupancy grid dimensions, resolution, and world-space origin.
- **Grid manipulation**: `reset_map`, `set_pose`, `set_point`, `set_points_world`, `draw_map`.
- **Occupancy export**: `get_occupancy_grid`, `get_occupancy_meta` — used by the planner to read the occupancy grid.
- **Planned path overlay**: `clear_planned_path`, `set_planned_path_cell`, `set_planned_goal_cell` — allow the planner to draw its path on the map image.
- **Image accessors**: `get_image_rgba_ptr`, `get_image_rgba_size`, `get_image_width`, `get_image_height`.
- **`rerun_log_map_frame(MapFrame*)`** — host-imported; sends the rendered map image to Rerun.

### `map.cpp`
The occupancy grid and image renderer. Operates entirely in static memory (no heap allocation for the grid):

**Grid model** (400×400 cells, 2 cm resolution):
- **`SCAN_COUNT[i]`** — hit counter per cell. Incremented when a ray endpoint lands on a cell; decremented (decayed) for cells a ray passes through.
- **`CONFIRMED[i]`** — binary flag; set when `SCAN_COUNT ≥ 5` (occupied), cleared when count drops below 1 (free-space evidence clears stale obstacles).
- **`VISITED[i]`** — tracks whether a cell has ever been observed by a ray.
- Occupancy convention (ROS-compatible): `-1` = unknown, `0` = free, `100` = occupied.

**Ray integration** (`integrate_ray` / `integrate_scan`):
- Bresenham line tracing from the robot cell to each point endpoint.
- Cells along the ray are marked visited and their scan count is decayed (evidence of free space).
- The endpoint cell's scan count is incremented (evidence of obstacle).
- Points in robot-local frame are transformed to world using the latest pose; points already in world frame are used directly (controlled by `POINTS_IN_WORLD`).

**Rendering** (`draw_map`):
- Outputs a 256×256 (configurable) RGBA image.
- Uses cached pixel→grid lookup tables (`PIXEL_TO_GX`, `PIXEL_TO_GY`) to avoid per-pixel floating-point math.
- Layers drawn (bottom to top):
  1. Occupancy grid: gray=unknown, black=free, white=occupied.
  2. Current LiDAR scan points (magenta dots).
  3. Wheel-odometry path history (purple polyline).
  4. Planned A* path (blue polyline via `draw_planned_path_overlay`).
  5. Goal marker (blue crosshair via `draw_goal_marker`).
  6. Current robot pose (3×3 white dot + red forward axis + green left axis).

### `map_update.h` / `map_update.cpp`
Glue between the raw LiDAR thread and `map.cpp`:

- **`build_rerun_frame_from_lidar()`** — transforms raw sensor points into body frame (applying camera-to-body mounting correction of +90° roll), filters by height and range, subsamples for Rerun, and optionally highlights map-eligible points in magenta.
- **`update_map_from_lidar()`** — the main per-frame map update:
  1. Transforms points from sensor frame → world frame via the body-to-world pose.
  2. Applies height filter (`0.1 m < z_world < 0.25 m`) and range filter (`< 1.8 m`) to keep only relevant obstacle points.
  3. Subsamples if point count exceeds 20,000.
  4. Calls `set_point(...)` for each accepted point, then `draw_map(...)` at the rendering interval.
  5. Logs performance metrics (point loop time, draw time, update rate) every 2 seconds.

### `costmap.h`
Placeholder header (currently empty). Reserved for future explicit costmap logic.

---

## Planning (`planning/`)

### `planner.h`
General-purpose 2D grid-based A* path planner:

**Data structures**:
- **`GridMap2D`** — occupancy grid with ROS-style `int8_t` cells (`-1`=unknown, `0`–`100`=occupancy probability).
- **`GridCoord`** — (x, y) grid cell coordinate.
- **`PlannerConfig`** — tunable parameters:
  - `occupied_threshold` (50), `treat_unknown_as_occupied` (true)
  - `inflation_radius_m` (0.05 m default, 0.20 m in practice)
  - `allow_diagonal`, `prevent_corner_cutting`
  - `snap_start_to_free`, `snap_goal_to_free` with configurable search radius
  - `max_expanded_nodes` (250,000 — prevents runaway search on large grids)
  - `simplify_path` — post-process with line-of-sight simplification

**Key algorithms**:
- **`inflate_obstacles()`** — circular kernel inflation. Marks all free cells within `inflation_radius_m` of an occupied or unknown cell as occupied.
- **`AStarPlanner::plan_to_grid()`** — standard A* with Euclidean heuristic. Supports 4-connected or 8-connected grids with diagonal corner-cutting prevention. Returns a `PlanResult` with both grid-cell and world-coordinate paths.
- **`simplify_grid_path()`** — greedy line-of-sight path simplification using Bresenham ray checks.
- **`find_nearest_free_cell()`** — spiral outward search to snap a blocked start/goal to the nearest traversable cell.

### `frontier_explorer.h` / `frontier_explorer.cpp`
Autonomous frontier-based exploration:

- **`FrontierExplorerConfig`** — mirrors `PlannerConfig` plus `min_cluster_size` (minimum 4 cells to be a valid frontier).
- **`plan_to_nearest_frontier()`** — the top-level exploration function:
  1. Loads and inflates the occupancy grid.
  2. Snaps the robot start cell to free space if needed.
  3. **BFS reachability flood-fill** (`mark_reachable_cells`) from the robot's position through the inflated grid.
  4. **Frontier detection** (`detect_frontiers`): a reachable, known-free cell adjacent to at least one unknown cell is a frontier cell.
  5. **8-connected clustering** (`cluster_frontiers`): groups frontier cells into contiguous clusters.
  6. **Cluster goal selection** (`select_cluster_goal_cell`): picks the cell nearest each cluster's centroid.
  7. **Nearest-cluster selection**: runs A* to each cluster's representative cell; picks the cluster with the shortest reachable path (breaking ties by cluster size).
- Returns a `FrontierPlanResult` with path, goal cell, frontier statistics.

### `planner_bridge.h` / `planner_bridge.cpp`
Connects the planner to the mapping and control threads:

- **Manual goal mode**: `set_goal_map_pixel(x, y)` / `clear_goal()` — the host UI can tap on the map to set a goal pixel. The bridge converts render-pixel → grid-cell → A* path.
- **Auto frontier mode** (default when no manual goal): On a 0.75 s replan interval, calls `plan_to_nearest_frontier()` and publishes the result.
- **`update_plan_overlay()`** — called by the mapping thread after each map update. Runs the planner, pushes the planned path cells into `map.cpp` for visualization, and caches the world-coordinate path.
- **`copy_latest_plan_world()`** — thread-safe accessor; the control thread polls this to get the latest planned path. Returns a revision number so the control thread can detect when the path changes.
- **Exported C functions**: `set_planner_goal_map_pixel()` and `clear_planner_goal_map_pixel()` — callable from Swift.

### `navigation.h` / `navigation.cpp`
Early-stage / skeleton exploration algorithm. Contains stub definitions for `initial_spin`, `find_frontiers`, `cluster_frontiers`, and `explore_full_map`. The actual implementation has been superseded by `frontier_explorer.cpp` and the state machine in `slam_main.cpp`.

---

## Controls (`controls/`)

### `motors.h`
Motor interface and closed-loop speed controllers:

**Host interface**:
- **`MotorCommand`** — `{left_percent, right_percent, hold_ms}`. Sent to the host via `write_motors()`.
- **`TwistCommand`** — `{v_mps, omega_rad_s, hold_ms}`. Body-frame velocity command.

**Differential drive kinematics**:
- `wheel_speed_setpoint_from_twist()` — converts `(v, ω)` to individual wheel speeds: `v_left = v - ω·(B/2)`, `v_right = v + ω·(B/2)`.
- Speed limits: `|v| ≤ 0.3 m/s`, `|ω| ≤ π rad/s`.

**`WheelSpeedPercentController`** — per-wheel PI + feedforward controller:
- Feedforward: `kff · desired_speed` — maps desired m/s to approximate motor percent.
- Proportional: `kp · (desired - measured)`.
- Integral: `ki · ∫error·dt` with anti-windup clamping.
- Default gains: `kff=60, kp=30, ki=10, integral_limit=10`.

**`MotorController`** — high-level API:
- `drive_percent(left, right, hold_ms)` — raw open-loop command.
- `drive_twist(cmd, odom)` — closed-loop twist using wheel odometry feedback.
- `drive_turn_to_yaw(current, target, odom, config)` — outer-loop proportional yaw controller for turn-in-place maneuvers. Returns `true` when within `yaw_tolerance_rad` (default 3°).
- `drive_twist_for(v, ω, duration_ms)` — blocking twist demo helper.
- `stop()` — immediate zero command.

### `path_following.h`
Waypoint path-following controller:

**`PathFollower`** class:
- Accepts a world-coordinate path (`vector<Vector3d>`) and tracks progress along it.
- **`update(pose, dt, hold_ms)`** — called once per odometry sample:
  1. Advances past reached waypoints (`waypoint_reached_m = 0.08 m`).
  2. Selects a lookahead point (`lookahead_m = 0.14 m` ahead of the robot).
  3. Computes distance and heading error to the lookahead point.
  4. Runs dual PID controllers:
     - **Distance PID** (`kp=1.8, kd=0.12`) → linear velocity command.
     - **Heading PID** (`kp=3.6, kd=0.22`) → angular velocity command.
  5. Applies a **heading gate** — reduces forward speed proportionally to `cos(heading_error)` to avoid overshoot while turning.
  6. Applies **goal slowdown** — linearly reduces speed within the lookahead radius of the final goal.
  7. Applies **slew rate limits** (`0.8 m/s², 6.0 rad/s²`) to smooth acceleration.
  8. Returns a `PathFollowerStatus` with the twist command and goal-reached flag.
- Goal tolerance: 0.05 m position, 0.22 rad heading.

---

## Thread Model & Data Flow

`slam_main.cpp` runs **5 threads** (all created in `main()`):

| Thread | Rate | Responsibilities |
|---|---|---|
| **IMU** | ~100 Hz | Reads IMU, updates calibration, integrates orientation |
| **LiDAR Camera** | ~30 Hz | Reads LiDAR+camera frames into a double buffer |
| **Mapping** | 10 Hz (map), 30 Hz (rerun) | Transforms points to world frame, updates occupancy grid, renders map image, runs planner overlay |
| **Control** | ~50–100 Hz (odometry-driven) | Reads wheel encoders, integrates odometry, executes initial spin, follows planned paths |
| **Autonomy** | One-shot transitions | Waits for sensor readiness, transitions state machine |

### Data Flow

```
IMU Thread ──→ g_imu_calib / g_imu_preintegrator ──→ g_latest_quat_imu
                                                         (diagnostic only)

LiDAR Thread ──→ g_lc_buffers[0/1] ──→ Mapping Thread ──→ map.cpp (occupancy grid)
                 (double buffered)           │                    │
                                             │              planner_bridge
                                             │                    │
                                             ├──→ rerun_log_*     ├──→ g_planned_path_world
                                             │                    │
Control Thread ──→ read_wheel_odometry       │              Control Thread
      │            integrate (x, y, yaw)     │                    │
      │                  │                   │              path_follower.update()
      │                  ▼                   │                    │
      │            g_pose (mutex) ───────────┘              drive_twist()
      │                                                          │
      └──────────────────────────────────────────────→ write_motors()
```

### Synchronization

- **`g_pose`** is protected by `m_pose` mutex. Written by the control thread, read by mapping.
- **LiDAR double buffer** uses atomics (`g_lc_ready_idx`, `g_lc_in_use_idx`) for lock-free producer/consumer coordination.
- **Planned path** is protected by `g_planned_path_mutex` inside `planner_bridge.cpp`.
- **State transitions** use `g_state` (atomic) and latched readiness flags (`g_imu_ready`, `g_lc_ready`, `g_wheel_odom_ready`, `g_first_map_update_done`, `g_initial_spin_done`).

---

## State Machine

```
SENSOR_INIT ──────────────────→ AUTONOMY_INIT ──────────────→ AUTONOMY_ENGAGED
  (wait for IMU calibration,      (4-segment 360° spin         (frontier exploration
   LiDAR frames, wheel odom)       for initial map)             + path following)
```

### `SENSOR_INIT`
- All sensor threads start and begin producing data.
- The autonomy thread blocks until `g_imu_ready`, `g_lc_ready`, and `g_wheel_odom_ready` are all true.

### `AUTONOMY_INIT`
- The robot performs a **closed-loop initial spin** to build an initial 360° occupancy map:
  - 4 segments × 90° each = full rotation.
  - Each segment uses `drive_turn_to_yaw()` against wheel-odometry yaw.
  - After each segment, the robot pauses and waits for a fresh map revision (or a 1.5 s timeout) before continuing.
- Only starts after the first map update has completed.
- Transitions to `AUTONOMY_ENGAGED` when all 4 segments are done.

### `AUTONOMY_ENGAGED`
- The control thread polls `copy_latest_plan_world()` for new paths from the planner.
- The planner (running in the mapping thread) automatically runs frontier exploration every 0.75 s, finding the nearest reachable frontier cluster and computing an A* path to it.
- The `PathFollower` tracks the planned path and outputs twist commands to the motor controller.
- When a goal is reached, the path is cleared and the robot waits for a new path from the next frontier replan cycle.
- The host can override automatic exploration by tapping the map to set a manual goal pixel.

---

## Configuration Constants

Key tuning knobs scattered across the codebase:

| Constant | File | Value | Description |
|---|---|---|---|
| `kMaxLinearSpeedMps` | `motors.h` | 0.3 m/s | Maximum forward/reverse speed |
| `kMaxAngularSpeedRadPerSec` | `motors.h` | π rad/s | Maximum yaw rate |
| `kWheelBaseMeters` | `wheel_odometry.h` | 0.155 m | Distance between wheel centers |
| `kWheelRadiusMeters` | `wheel_odometry.h` | 0.025 m | Wheel radius |
| `kWheelTicksPerRev` | `wheel_odometry.h` | 16,384 | Encoder ticks per wheel revolution |
| `IMURefreshHz` | `imu.h` | 100 Hz | IMU polling rate |
| `LidarCameraRefreshHz` | `lidar_camera.h` | 30 Hz | LiDAR/camera polling rate |
| `GRID_RESOLUTION` | `map.cpp` | 0.02 m | Occupancy grid cell size |
| `MAP_SIZE_X/Y` | `map.cpp` | 400×400 | Occupancy grid dimensions (8 m × 8 m) |
| `SCAN_THRESHOLD` | `map.cpp` | 5 | Hits needed to confirm a cell as occupied |
| `mapMaxRangeMeters` | `map_update.cpp` | 1.8 m | Maximum range for map-eligible points |
| `mapMinZ / mapMaxZ` | `map_update.cpp` | 0.1 / 0.25 m | Height band filter (world frame) |
| `sensorHeightMeters` | `map_update.cpp` | 0.20 m | Sensor mounting height above world origin |
| `inflation_radius_m` | `planner_bridge.cpp` | 0.20 m | Obstacle inflation for planning |
| `kAutoFrontierReplanIntervalSec` | `planner_bridge.cpp` | 0.75 s | Frontier replan period |
| `kInitialSpinSegments` | `slam_main.cpp` | 4 | Quarter turns in the initial spin |
| `kInitialSpinStepRad` | `slam_main.cpp` | π/2 | Radians per spin segment |
| `kPathFollowHoldMs` | `slam_main.cpp` | 120 ms | Motor command hold time during path following |
| `lookahead_m` | `path_following.h` | 0.14 m | Path follower lookahead distance |
| `goal_tolerance_m` | `path_following.h` | 0.05 m | Goal reached position tolerance |
