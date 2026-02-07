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
    // Map device vectors into FLU (+X forward, +Y left, +Z up).
    static let deviceToFluMatrix: simd_double3x3 = {
        // Columns are device basis vectors expressed in FLU.
        let c0 = SIMD3<Double>(0.0, -1.0, 0.0) // device +X (right) -> FLU -Y (right)
        let c1 = SIMD3<Double>(0.0, 0.0, 1.0)  // device +Y (up) -> FLU +Z (up)
        let c2 = SIMD3<Double>(-1.0, 0.0, 0.0) // device +Z (toward user) -> FLU -X (forward)
        return simd_double3x3(columns: (c0, c1, c2))
    }()

    static func deviceToFlu(_ v: SIMD3<Double>) -> SIMD3<Double> {
        deviceToFluMatrix * v
    }

    static func deviceToFlu(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let dv = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
        let out = deviceToFluMatrix * dv
        return SIMD3<Float>(Float(out.x), Float(out.y), Float(out.z))
    }

    // Convert CoreMotion rotation matrix into FLU (ref -> flu).
    static func refToFlu(fromDeviceRotation r: CMRotationMatrix) -> simd_quatd {
        // CMRotationMatrix rotates vectors from the reference frame into the device frame.
        // Build R_dev_from_ref in column-major form, then map device -> FLU.
        let c0 = SIMD3<Double>(r.m11, r.m21, r.m31)
        let c1 = SIMD3<Double>(r.m12, r.m22, r.m32)
        let c2 = SIMD3<Double>(r.m13, r.m23, r.m33)
        let rDevFromRef = simd_double3x3(columns: (c0, c1, c2))
        let rFluFromRef = deviceToFluMatrix * rDevFromRef
        return simd_quatd(rFluFromRef)
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
    var att_timestamp: Double
    var quat_x: Double
    var quat_y: Double
    var quat_z: Double
    var quat_w: Double
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
    var currentData = IMUData(
        acc_timestamp: 0, acc_x: 0, acc_y: 0, acc_z: 0,
        gyro_timestamp: 0, gyro_x: 0, gyro_y: 0, gyro_z: 0,
        att_timestamp: 0, quat_x: 0, quat_y: 0, quat_z: 0, quat_w: 1
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
                let qFluFromRef = CoordinateFrames.refToFlu(fromDeviceRotation: motion.attitude.rotationMatrix)
                self.lock.lock()
                self.currentAttitude = AttitudeData(
                    timestamp: motion.timestamp,
                    quat_x: qFluFromRef.imag.x,
                    quat_y: qFluFromRef.imag.y,
                    quat_z: qFluFromRef.imag.z,
                    quat_w: qFluFromRef.real
                )
                self.currentData.att_timestamp = motion.timestamp
                self.currentData.quat_x = qFluFromRef.imag.x
                self.currentData.quat_y = qFluFromRef.imag.y
                self.currentData.quat_z = qFluFromRef.imag.z
                self.currentData.quat_w = qFluFromRef.real
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

    let manager = IMUManager.shared
    manager.lock.lock()
    let data = manager.currentData
    manager.lock.unlock()

    // Write field-by-field to match the WASM IMUData layout (Double packed).
    let fieldCount = 13
    let base = ptr.bindMemory(to: Double.self, capacity: fieldCount)
    base[0] = data.acc_timestamp
    base[1] = data.acc_x
    base[2] = data.acc_y
    base[3] = data.acc_z
    base[4] = data.gyro_timestamp
    base[5] = data.gyro_x
    base[6] = data.gyro_y
    base[7] = data.gyro_z
    base[8] = data.att_timestamp
    base[9] = data.quat_x
    base[10] = data.quat_y
    base[11] = data.quat_z
    base[12] = data.quat_w
}
