//
//  IMUManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

import Foundation
import CoreMotion
import QuartzCore
import simd

enum CoordinateFrames {
    // Camera depth unprojection yields RDF: +X right, +Y down, +Z forward.
    // Convert to FLU: +X forward, +Y left, +Z up.
    static func cameraRdfToFlu(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(p.z, -p.x, -p.y)
    }

    static func cameraRdfToFlu(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(p.z, -p.x, -p.y)
    }

    // Device axes (portrait): +X right, +Y up, +Z out of screen (toward user).
    // Back-camera forward is -Z. Map device vectors into FLU.
    static func deviceToFlu(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(-v.z, -v.x, v.y)
    }

    static let deviceToFluRotation: simd_quatd = {
        // Columns are device basis vectors expressed in FLU.
        let c0 = SIMD3<Double>(0.0, -1.0, 0.0) // device +X -> FLU
        let c1 = SIMD3<Double>(0.0, 0.0, 1.0)  // device +Y -> FLU
        let c2 = SIMD3<Double>(-1.0, 0.0, 0.0) // device +Z -> FLU
        let m = simd_double3x3(columns: (c0, c1, c2))
        return simd_quatd(m)
    }()

    static func deviceAttitudeToFlu(_ qDeviceFromRef: simd_quatd) -> simd_quatd {
        deviceToFluRotation * qDeviceFromRef
    }
}

// IMU samples in FLU coordinates: +X forward, +Y left, +Z up.
struct IMUData {
    var acc_timestamp: Double
    var acc_x: Double
    var acc_y: Double
    var acc_z: Double
    var gyro_timestamp: Double
    var gyro_x: Double
    var gyro_y: Double
    var gyro_z: Double
}

// Attitude quaternion in FLU coordinates (xyzw).
struct AttitudeData {
    var timestamp: Double
    var quat_x: Double
    var quat_y: Double
    var quat_z: Double
    var quat_w: Double
}

class IMUManager {
    static let shared = IMUManager()

    private let motionManager = CMMotionManager()
    private var lastPoseSendTime: CFTimeInterval = 0
    private let poseSendInterval: CFTimeInterval = 1.0 / 30.0  // throttle to ~30 Hz

    let lock = NSLock()
    var currentData = IMUData(acc_timestamp: 0, acc_x: 0, acc_y: 0, acc_z: 0, gyro_timestamp: 0, gyro_x: 0, gyro_y: 0, gyro_z: 0
    )
    var currentAttitude = AttitudeData(timestamp: 0, quat_x: 0, quat_y: 0, quat_z: 0, quat_w: 1)

    private init() {}

    func start() {
        let IMUIntervalHz = 100.0 // same for accelerometer and gyro

        let motionUpdateInterval = 1.0 / IMUIntervalHz
        let gravityToMetersPerSecondSquared = 9.80665

        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = motionUpdateInterval
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] (data, _) in
                guard let self = self, let data = data else { return }
                let accDevice = SIMD3<Double>(
                    data.acceleration.x * gravityToMetersPerSecondSquared,
                    data.acceleration.y * gravityToMetersPerSecondSquared,
                    data.acceleration.z * gravityToMetersPerSecondSquared
                )
                let accFlu = CoordinateFrames.deviceToFlu(accDevice)
                self.lock.lock()
                self.currentData.acc_timestamp = data.timestamp
                self.currentData.acc_x = accFlu.x
                self.currentData.acc_y = accFlu.y
                self.currentData.acc_z = accFlu.z
                self.lock.unlock()
            }
        }

        if motionManager.isGyroAvailable {
            motionManager.gyroUpdateInterval = motionUpdateInterval
            motionManager.startGyroUpdates(to: .main) { [weak self] (data, _) in
                guard let self = self, let data = data else { return }
                let gyroDevice = SIMD3<Double>(
                    data.rotationRate.x,
                    data.rotationRate.y,
                    data.rotationRate.z
                )
                let gyroFlu = CoordinateFrames.deviceToFlu(gyroDevice)
                self.lock.lock()
                self.currentData.gyro_timestamp = data.timestamp
                self.currentData.gyro_x = gyroFlu.x
                self.currentData.gyro_y = gyroFlu.y
                self.currentData.gyro_z = gyroFlu.z
                self.lock.unlock()
            }
        }

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz for pose
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] (motion, _) in
                guard let self = self, let motion = motion else { return }
                let q = motion.attitude.quaternion
                let qDeviceFromRef = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
                let qFluFromRef = CoordinateFrames.deviceAttitudeToFlu(qDeviceFromRef)
                self.lock.lock()
                self.currentAttitude = AttitudeData(
                    timestamp: motion.timestamp,
                    quat_x: qFluFromRef.imag.x,
                    quat_y: qFluFromRef.imag.y,
                    quat_z: qFluFromRef.imag.z,
                    quat_w: qFluFromRef.real
                )
                self.lock.unlock()

                // Stream pose to Rerun (throttled)
                let now = CACurrentMediaTime()
                if now - self.lastPoseSendTime >= self.poseSendInterval {
                    self.lastPoseSendTime = now
                    RerunWebSocketClient.shared.logPose(
                        timestamp: motion.timestamp,
                        quaternion: [
                            qFluFromRef.imag.x,
                            qFluFromRef.imag.y,
                            qFluFromRef.imag.z,
                            qFluFromRef.real
                        ]
                    )
                }
            }
        }
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
    }
}

// exported function for Wasm
func read_imu_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

    // Bind memory to IMUData struct
    let imuDataPtr = ptr.bindMemory(to: IMUData.self, capacity: 1)

    let manager = IMUManager.shared
    manager.lock.lock()
    let data = manager.currentData
    manager.lock.unlock()

    imuDataPtr.pointee = data
}
