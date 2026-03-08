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