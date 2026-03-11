# WASM Runtime

This directory is the robot runtime that gets compiled to `slam_main.wasm` and hosted by the iOS app through WAMR. The best entrypoint for understanding the system is [WASM/slam_main.cpp](/Users/thomasonzhou/src/roamr/WASM/slam_main.cpp). A mirrored copy also exists at [iOS/roamr/WASM/slam_main.cpp](/Users/thomasonzhou/src/roamr/iOS/roamr/WASM/slam_main.cpp), but the code in this directory should be treated as the source of truth.


Build from [WASM/build_wasm.sh](/Users/thomasonzhou/src/roamr/WASM/build_wasm.sh):

```sh
cd WASM
./build_wasm.sh
```

The script currently compiles:

- `slam_main.cpp`
- `core/telemetry.cpp`
- `mapping/map.cpp`
- `mapping/map_update.cpp`
- `mapping/visualization.cpp`
- `planning/frontier_explorer.cpp`
- `planning/frontier_simplified.cpp`
- `planning/planner_bridge.cpp`
- `sensors/imu_calibration.cpp`
- `sensors/imu_preintegration.cpp`

Target details:

- `wasm32-wasip1-threads`
- shared memory enabled
- exceptions and RTTI disabled
- output: `slam_main.wasm`

This runtime does not link protobuf-lite. Recording code writes protobuf-wire-
compatible bytes directly, and [WASM/proto/roamr_log.proto](/Users/thomasonzhou/src/roamr/WASM/proto/roamr_log.proto)
remains the schema for desktop/offline tooling.

## Host Boundary

The WASM module does not own devices directly. It talks to the iOS host through imported functions and a small exported API.

Imported from the host:

- IMU reads
- LiDAR + camera frame reads
- wheel odometry reads
- motor writes
- telemetry / text logging

Exported to the host:

- `set_planner_goal_map_pixel`
- `clear_planner_goal_map_pixel`

Those exports let the UI set or clear a manual planning target on the rendered map.

## Runtime Overview

`main()` starts seven long-lived threads:

| Thread | Purpose |
| --- | --- |
| `autonomy_thread` | waits for readiness, runs the initial scan, services scan requests |
| `imu_thread` | calibrates IMU biases, integrates orientation, updates the IMU side of `g_pose` |
| `lidar_camera_thread` | reads LiDAR/camera frames into a queued slot buffer and samples pose history for each frame |
| `mapping_thread` | consumes queued LiDAR frames, updates the occupancy map, publishes snapshots and map deltas |
| `planner_thread` | wakes on map/goal changes, computes overlays and world paths |
| `telemetry_thread` | renders map frames plus pose/path/frontier overlays for the host |
| `control_thread` | reads wheel odometry, maintains the shared pose, follows planned paths, drives motors |

This split matters:

- mapping no longer renders the final map image
- planning no longer runs inside the mapping loop
- LiDAR is no longer a two-slot latest-frame handoff

## State Machine

There are two layers of runtime state:

- `g_state`: coarse lifecycle state
- `g_autonomy_substate`: finer autonomy/debug state from [WASM/autonomy/autonomy.h](/Users/thomasonzhou/src/roamr/WASM/autonomy/autonomy.h)

Top-level lifecycle:

```text
SENSOR_INIT -> AUTONOMY_INIT -> AUTONOMY_ENGAGED
```

### `SENSOR_INIT`

The autonomy thread waits for:

- IMU calibration to complete
- at least one non-empty LiDAR frame
- wheel odometry readiness when the selected pose mode depends on wheel odom


### `AUTONOMY_INIT`

The runtime waits for the first real map update, then performs an initial closed-loop `scan_4x90()` if scanning is enabled.

That scan:

- rotates in four quarter-turn segments
- uses wheel/pose feedback, not a blind timed turn
- stops and settles after each segment
- exists to seed the initial occupancy map before normal autonomy begins

### `AUTONOMY_ENGAGED`

Once engaged:

- the planner reacts to map and goal updates
- the control loop follows the latest world-frame path
- failed planning can request another scan
- reaching a goal also requests another scan so new free space can be exposed

Autonomy substates include:

- `PLANNER_INIT`: waiting for planner to initialize from the initial map after scanning 4x90
- `WAITING_FOR_PATH`: planner started and is drawing paths
- `FRONTIER_DETECTION`
- `GOAL_SELECTION`
- `PLANNING_GOAL`
- `FOLLOWING_PATH`
- `NO_PATH_AVAILABLE`
- `SCAN_REQUESTED`
- `SCANNING`: 4x90 loop to refresh local map

## Shared Data Flow

The runtime is built around a few published handoff points rather than one giant loop.

### Pose

`g_pose` is the shared robot pose. It is protected by `m_pose`, and a short pose history buffer is also maintained so LiDAR frames can be associated with a pose near their timestamp.

Current compile-time pose mode in [WASM/slam_main.cpp](/Users/thomasonzhou/src/roamr/WASM/slam_main.cpp) is `fused_IMU_wheel_odom`:

- wheel odometry provides translation
- IMU integration provides the current heading quaternion

That is still a lightweight fusion path, not a full estimator. The code comments correctly note that raw IMU preintegration drifts and should not be treated as a final long-term orientation solution.

### LiDAR / Camera Queue

LiDAR frames move through a four-slot queue:

- slot states: `FREE`, `WRITING`, `QUEUED`, `READING`
- producer: `lidar_camera_thread`
- consumer: `mapping_thread`

For each frame, the producer:

1. claims a free slot
2. reads host LiDAR/camera data
3. converts points into FLU
4. samples pose history at the frame timestamp
5. queues the slot for mapping

This is a real queued producer/consumer pipeline, not the older "latest frame wins" double buffer.

### Mapping Publication

The mapping thread consumes queued LiDAR frames, filters/transforms points, and updates `mapping::Map`.

Each successful update publishes:

- a monotonic `g_map_update_revision`
- `g_latest_map_snapshot`
- `g_latest_map_state`
- a `MapDeltaEvent` with newly occupied cells for the planner

That delta queue is what lets planning skip unnecessary replans when the new obstacle evidence does not intersect the current path corridor.

### Planning Publication

The planner thread wakes on:

- goal changes
- map revisions
- queued map deltas

It reads the latest published snapshot, updates a `PlanningOverlay`, and caches the world-frame path exposed through `planning::bridge::copy_latest_plan_world(...)`.

Two planning modes exist:

- manual goal mode: a UI pixel is converted to a map cell and planned directly
- automatic frontier mode: when no manual goal is active, the planner searches for reachable frontiers

The current bridge logic in [WASM/planning/planner_bridge.cpp](/Users/thomasonzhou/src/roamr/WASM/planning/planner_bridge.cpp):

- keeps a D* Lite planner for direct goal planning
- rate-limits automatic frontier replans
- caches frontier goal candidates across replans
- invalidates the current plan when the controller reaches the goal

### Telemetry

The telemetry thread renders the published map snapshot plus:

- pose trail
- planned path
- frontier candidates
- selected frontier cluster / seed

Rendering happens in [WASM/mapping/visualization.h](/Users/thomasonzhou/src/roamr/WASM/mapping/visualization.h) and its `.cpp`, separate from occupancy integration.

## Subsystem Notes

### Sensors

- [WASM/sensors/calibration.h](/Users/thomasonzhou/src/roamr/WASM/sensors/calibration.h) and [WASM/sensors/imu_calibration.cpp](/Users/thomasonzhou/src/roamr/WASM/sensors/imu_calibration.cpp) handle stillness-based IMU bias estimation and recalibration.
- [WASM/sensors/imu_preintegration.h](/Users/thomasonzhou/src/roamr/WASM/sensors/imu_preintegration.h) and `.cpp` integrate IMU orientation.
- [WASM/sensors/lidar_camera.h](/Users/thomasonzhou/src/roamr/WASM/sensors/lidar_camera.h) defines the host frame payload and point-frame conversion helpers.
- [WASM/sensors/wheel_odometry.h](/Users/thomasonzhou/src/roamr/WASM/sensors/wheel_odometry.h) handles differential-drive odometry integration and wheel-speed estimation.

### Mapping

- [WASM/mapping/map.cpp](/Users/thomasonzhou/src/roamr/WASM/mapping/map.cpp) owns the occupancy grid.
- [WASM/mapping/map_update.h](/Users/thomasonzhou/src/roamr/WASM/mapping/map_update.h) and `.cpp` translate LiDAR frames into map updates and snapshots.
- [WASM/mapping/map_snapshot.h](/Users/thomasonzhou/src/roamr/WASM/mapping/map_snapshot.h) is the planner/telemetry handoff format.
- [WASM/mapping/costmap.h](/Users/thomasonzhou/src/roamr/WASM/mapping/costmap.h) builds the inflated navigation costmap used by planning.

### Planning

- [WASM/planning/planner.h](/Users/thomasonzhou/src/roamr/WASM/planning/planner.h) provides grid planning utilities.
- [WASM/planning/frontier_explorer.cpp](/Users/thomasonzhou/src/roamr/WASM/planning/frontier_explorer.cpp) implements reachable-frontier selection.
- [WASM/planning/planner_bridge.h](/Users/thomasonzhou/src/roamr/WASM/planning/planner_bridge.h) and `.cpp` are the thread boundary between mapping/control/UI.

### Controls

- [WASM/controls/motors.h](/Users/thomasonzhou/src/roamr/WASM/controls/motors.h) converts twist commands to wheel commands and writes motors through the host.
- [WASM/controls/path_following.h](/Users/thomasonzhou/src/roamr/WASM/controls/path_following.h) tracks the published world path and produces velocity commands.

## Current Behavior Summary

If you want the shortest accurate mental model for `slam_main.cpp`, it is this:

1. Bring up IMU, LiDAR, and wheel odometry.
2. Publish a shared pose and short pose history.
3. Queue LiDAR frames with timestamp-matched poses into the mapper.
4. Publish map snapshots and occupancy deltas.
5. Replan only when the map, goal, or current path validity actually changes.
6. Follow the current world path until the goal is reached or planning fails.
7. Trigger another scan when exploration stalls or a goal completes.

## Historical Notes

[WASM/implementation_notes.md](/Users/thomasonzhou/src/roamr/WASM/implementation_notes.md) is still useful for context, but it should be read as design history rather than the current runtime contract. When that file and `slam_main.cpp` disagree, trust `slam_main.cpp`.

