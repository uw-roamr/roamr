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
- Kept `g_map_initialized` as mapping-internal state instead of reusing it as a cross-thread readiness signal.
- Made `g_state` atomic because it is shared across threads.

### IMU calibration / logging

- Initial IMU calibration still happens in `init_biases()`.
- Recalibration still updates biases when the device is still, but repeated `"recalibrated IMU"` spam was removed.
- Current UI logging only reports the initial calibration event and gravity initialization message.

### Current turn demo

- The current demo is still a blind open-loop turn used as a stepping stone before closed-loop autonomy.
- It now uses a non-blocking timed motor-command loop in the control thread instead of `drive_for(...)`.
  - This keeps odometry and `g_pose` updating while the robot rotates.
  - That is important because blocking the control thread prevented mapping from seeing pose motion during the turn.
- The turn starts only after:
  - LiDAR has produced a valid frame
  - the mapping thread has completed at least one map update
- Current demo constants in `slam_main.cpp`:
  - left motor = `-18`
  - right motor = `18`
  - duration = `2600 ms`
  - hold time = `150 ms`

### Important debugging lessons

- Teleop working does not imply the first WASM turn demo is valid:
  - `drive_twist_for(...)` depends on valid wheel odometry before it emits commands
  - teleop sends raw motor text immediately
- The earlier black-screen-on-launch issue was mostly due to debugger / console overhead, not the app being truly frozen.
- App startup also improved by delaying `BluetoothManager.shared` creation until Bluetooth-related tabs are shown.
- For mapping, blocking motion helpers are the wrong shape if pose estimation must continue during motion.

### Next likely steps

- Replace the blind timed turn with a closed-loop turn target using odometry yaw or gyro-derived yaw.
- Build fused pose = wheel `x/y` + gyro yaw before relying on mapping during rotation.
- After the initial spin works reliably, move on to frontier detection and inflated A* planning.
