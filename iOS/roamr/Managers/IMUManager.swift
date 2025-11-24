//
//  IMUManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

import Foundation
import CoreMotion

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

class IMUManager {
    static let shared = IMUManager()

    private let motionManager = CMMotionManager()
    let lock = NSLock()
    var currentData = IMUData(acc_timestamp: 0, acc_x: 0, acc_y: 0, acc_z: 0, gyro_timestamp: 0, gyro_x: 0, gyro_y: 0, gyro_z: 0
    )

    private init() {}

    func start() {
        let IMUIntervalHz = 100.0 // same for accelerometer and gyro

        let motionUpdateInterval = 1.0 / IMUIntervalHz
        let gravityToMetersPerSecondSquared = 9.80665

        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = motionUpdateInterval
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] (data, _) in
                guard let self = self, let data = data else { return }
                self.lock.lock()
                self.currentData.acc_timestamp = data.timestamp
                self.currentData.acc_x = data.acceleration.x * gravityToMetersPerSecondSquared
                self.currentData.acc_y = data.acceleration.y * gravityToMetersPerSecondSquared
                self.currentData.acc_z = data.acceleration.z * gravityToMetersPerSecondSquared
                self.lock.unlock()
            }
        }

        if motionManager.isGyroAvailable {
            motionManager.gyroUpdateInterval = motionUpdateInterval
            motionManager.startGyroUpdates(to: .main) { [weak self] (data, _) in
                guard let self = self, let data = data else { return }
                self.lock.lock()
                self.currentData.gyro_timestamp = data.timestamp
                self.currentData.gyro_x = data.rotationRate.x
                self.currentData.gyro_y = data.rotationRate.y
                self.currentData.gyro_z = data.rotationRate.z
                self.lock.unlock()
            }
        }
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
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
