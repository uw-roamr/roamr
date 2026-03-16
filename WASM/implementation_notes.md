## Plan outline is from Codex, implementation details are from me to implement

1. Add shared readiness/status fields and a real autonomy enum in WASM/slam_main.cpp.
    basic outer state machine:
    1. SENSOR_INIT (merges two states below)
       1. HARDWARE_INIT (waiting for all sensor communications to init)
       2. CALIBRATION_INIT (waiting for calibrations to complete)
    2. AUTONOMY_INIT (waiting for autonomy to start with an initial map by spinning in a circle)
       1. potential micro steps to adjust if the map is inadequate: tune controller, potentially update teleoperation in the bluetooth app
    3. AUTONOMY_ENGAGED (enter autonomy state machine)

2. Add gyro-yaw accumulation in the IMU path.
3. Build fused g_pose = wheel x/y + gyro yaw.
4. Implement the spin states only, with no frontier logic yet.
5. Add frontier detection on the occupancy grid.
6. Add nearest-reachable frontier selection via inflated A*.
7. Wire path following with conservative limits.
8. Add failsafes and timeouts last, then tighten them.

## Implemented so far

### Runtime / host integration

- Added a WASM-to-Swift text log bridge so WASM can push status text into the iOS UI.
- Added a console panel to the active WASM hub screen so logs are visible without relying on Xcode stdout.
- Increased the WAMR thread cap on iOS (`WasmManager`) to avoid crashing once the WASM app started using multiple threads.
- Reduced debugger-hostile logging:
  - removed most extra `print(...)` spam from Swift runtime / BLE paths
  - gated verbose BLE logging behind a disabled flag
  - removed most extra `std::cout` logging added during debugging

### Readiness / threading

- Kept the LiDAR double-buffer design:
  - `g_lc_ready_idx` publishes the latest complete slot
  - `g_lc_in_use_idx` prevents the producer from overwriting the slot the mapper is reading
- Added latched readiness flags:
  - `g_lc_ready` becomes true after the first non-empty LiDAR frame is published
  - `g_first_map_update_done` becomes true after the first successful map update
- Added `g_initial_spin_done` so `AUTONOMY_INIT` can wait for the initial mapping spin to finish before path-following begins.
- Kept `g_map_initialized` as mapping-internal state instead of reusing it as a cross-thread readiness signal.
- Made `g_state` atomic because it is shared across threads.

### IMU calibration / logging

- Initial IMU calibration still happens in `init_biases()`.
- Recalibration still updates biases when the device is still, but repeated `"recalibrated IMU"` spam was removed.
- Current UI logging only reports the initial calibration event and gravity initialization message.

### Pose fusion

- Added gyro-yaw accumulation in `IMUPreintegrator`, but this is currently treated as diagnostic / future-estimator plumbing, not as an authoritative shared orientation estimate.
- Important correction: IMU preintegration accumulates drift, so it is not suitable as a drop-in rotation estimate for the shared autonomy/map pose.
- The shared `g_pose` used by mapping, planning, and path following currently uses wheel odometry yaw again.
- If IMU orientation is reintroduced into the shared pose later, it should be through a proper bounded-drift estimator rather than raw preintegration.

### Current turn demo

- The initial spin is now a closed-loop `AUTONOMY_INIT` behavior instead of a blind open-loop turn.
- It uses `drive_turn_to_yaw(...)` against wheel-odometry yaw in 4 quarter-turn segments.
- Each segment waits for a fresh map revision before continuing so the mapper has a chance to integrate the new viewpoint.
- The spin starts only after:
  - LiDAR has produced a valid frame
  - the mapping thread has completed at least one map update
- Current spin constants in `slam_main.cpp`:
  - step = `pi / 2 rad`
  - segments = `4`
  - controller hold time = `120 ms`
  - map-wait timeout = `1500 ms`

### Planning / control

- The planner bridge computes an inflated A* path to the current goal pixel when a manual goal is active.
- When no manual goal is active, it now runs automatic frontier exploration:
  - load the occupancy grid from `mapping/map.cpp`
  - inflate obstacles using the same planner-side inflation model
  - BFS reachable free cells from the robot start cell
  - detect frontier cells as reachable known-free cells adjacent to unknown space
  - cluster frontier cells with 8-connectivity
  - choose the nearest reachable cluster by running inflated A* to each cluster representative
- `AUTONOMY_ENGAGED` now consumes the latest planned world path and feeds it into `PathFollower`.
- The controller still uses conservative limits and stops cleanly when no path is available or the goal is reached.

### Mapping performance

- Removed duplicated planned-path / goal rendering in `mapping/map.cpp`.
- Replaced point/pose reset loops with `memset(...)`.
- Added cached pixel-to-grid lookup tables for the occupancy raster pass so draw-time work does less per-pixel floating-point math.

### Important debugging lessons

- Teleop working does not imply the first WASM turn demo is valid:
  - `drive_twist_for(...)` depends on valid wheel odometry before it emits commands
  - teleop sends raw motor text immediately
- The earlier black-screen-on-launch issue was mostly due to debugger / console overhead, not the app being truly frozen.
- App startup also improved by delaying `BluetoothManager.shared` creation until Bluetooth-related tabs are shown.
- For mapping, blocking motion helpers are the wrong shape if pose estimation must continue during motion.

### Next likely steps

- Tune the spin and path-following gains against real robot behavior now that the loop is closed.
- Add a real bounded-drift attitude / heading estimator before relying on IMU-derived rotation in the shared pose.
- Improve frontier-goal quality:
  - evaluate better cluster scoring than shortest-path-only
  - add hysteresis / goal stickiness so replanning does not churn while the robot is already progressing toward a frontier
  - consider a spin-at-goal behavior to expose new unknown space before picking the next frontier
- Keep pushing mapping cost down, especially the per-scan ray integration path if it remains the runtime bottleneck.
