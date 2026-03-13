//
//  IMUManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

import Foundation
import CoreMotion
import simd

enum CoordinateFrameId: Int32 {
    case RDF = 0
    case FLU = 1
}

typealias FrameId = Int32

enum CoordinateFrames {
    // Camera depth unprojection yields RDF: +X right, +Y down, +Z forward.
    // Convert to FLU: +X forward, +Y left, +Z up.
    static func cameraRdfToFlu(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(p.z, -p.x, -p.y)
    }

    static func cameraRdfToFlu(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(p.z, -p.x, -p.y)
    }

    // Manual RUB (device) -> FLU mapping for IMU data.
    // x_flu = -z_rub, y_flu = -x_rub, z_flu = y_rub
    static func rubToFlu(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(-v.z, -v.x, v.y)
    }

    static func rubToFlu(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(-v.z, -v.x, v.y)
    }

}

// IMU samples in FLU coordinates: +X forward, +Y left, +Z up.
struct IMUData {
    var timestamp: Double
    var acc_x: Double
    var acc_y: Double
    var acc_z: Double
    var gyro_x: Double
    var gyro_y: Double
    var gyro_z: Double
    var frame_id: FrameId
}

class IMUManager {
    static let shared = IMUManager()

    private let motionManager = CMMotionManager()
    private let imuQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.roamr.imu"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    let lock = NSLock()
    var currentData = IMUData(
        timestamp: 0, acc_x: 0, acc_y: 0, acc_z: 0,
        gyro_x: 0, gyro_y: 0, gyro_z: 0,
        frame_id: CoordinateFrameId.FLU.rawValue
    )

    private init() {}

    private func resetCurrentDataLocked() {
        currentData = IMUData(
            timestamp: 0, acc_x: 0, acc_y: 0, acc_z: 0,
            gyro_x: 0, gyro_y: 0, gyro_z: 0,
            frame_id: CoordinateFrameId.FLU.rawValue
        )
    }

    func start() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
        lock.lock()
        resetCurrentDataLocked()
        lock.unlock()

        let IMUIntervalHz = 100.0 // same for accelerometer and gyro

        let motionUpdateInterval = 1.0 / IMUIntervalHz
        let gravityToMetersPerSecondSquared = 9.80665

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = motionUpdateInterval
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: imuQueue) { [weak self] (motion, _) in
                guard let self = self, let motion = motion else { return }
                let accDevice = SIMD3<Double>(
                    (motion.userAcceleration.x + motion.gravity.x) * gravityToMetersPerSecondSquared,
                    (motion.userAcceleration.y + motion.gravity.y) * gravityToMetersPerSecondSquared,
                    (motion.userAcceleration.z + motion.gravity.z) * gravityToMetersPerSecondSquared
                )
                let gyroDevice = SIMD3<Double>(
                    motion.rotationRate.x,
                    motion.rotationRate.y,
                    motion.rotationRate.z
                )
                let accFlu = CoordinateFrames.rubToFlu(accDevice)
                let gyroFlu = CoordinateFrames.rubToFlu(gyroDevice)
                self.lock.lock()
                self.currentData.timestamp = motion.timestamp
                self.currentData.acc_x = accFlu.x
                self.currentData.acc_y = accFlu.y
                self.currentData.acc_z = accFlu.z
                self.currentData.gyro_x = gyroFlu.x
                self.currentData.gyro_y = gyroFlu.y
                self.currentData.gyro_z = gyroFlu.z
                self.currentData.frame_id = CoordinateFrameId.FLU.rawValue
                self.lock.unlock()
            }
        }
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
        lock.lock()
        resetCurrentDataLocked()
        lock.unlock()
    }
}

// exported function for Wasm
func read_imu_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

    let manager = IMUManager.shared
    manager.lock.lock()
    let data = manager.currentData
    manager.lock.unlock()

    // Write field-by-field to match the WASM IMUData layout:
    // 7 Doubles followed by an Int32 frame_id.
    let doubleCount = 7
    let base = ptr.bindMemory(to: Double.self, capacity: doubleCount)
    base[0] = data.timestamp
    base[1] = data.acc_x
    base[2] = data.acc_y
    base[3] = data.acc_z
    base[4] = data.gyro_x
    base[5] = data.gyro_y
    base[6] = data.gyro_z
    let frameIdOffset = doubleCount * MemoryLayout<Double>.size
    ptr.advanced(by: frameIdOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
        rebounded.pointee = data.frame_id
    }
}
