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
//    var mag_x: Double
//    var mag_y: Double
//    var mag_z: Double
}

let IMUIntervalHz = 100.0; // same for accelerometer and gyro
// https://developer.apple.com/documentation/coremotion/getting-raw-gyroscope-events

class IMUManager {
    static let shared = IMUManager()
    
    private let motionManager = CMMotionManager()
    let lock = NSLock()
    var currentData = IMUData(acc_timestamp: 0, acc_x: 0, acc_y: 0, acc_z: 0, gyro_timestamp: 0, gyro_x: 0, gyro_y: 0, gyro_z: 0
// , mag_x: 0, mag_y: 0, mag_z: 0
    )
    
    private init() {}
    
    func start() {
        let motionUpdateInterval = 1.0 / IMUIntervalHz;
        let gravityToMetersPerSecondSquared = 9.80665
        
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = motionUpdateInterval;
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] (data, error) in
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
            motionManager.startGyroUpdates(to: .main) { [weak self] (data, error) in
                guard let self = self, let data = data else { return }
                self.lock.lock()
                self.currentData.gyro_timestamp = data.timestamp
                self.currentData.gyro_x = data.rotationRate.x
                self.currentData.gyro_y = data.rotationRate.y
                self.currentData.gyro_z = data.rotationRate.z
                self.lock.unlock()
            }
        }
        
//        if motionManager.isMagnetometerAvailable {
//            motionManager.magnetometerUpdateInterval = 0.1
//            motionManager.startMagnetometerUpdates(to: .main) { [weak self] (data, error) in
//                guard let self = self, let data = data else { return }
//                self.lock.lock()
//                self.currentData.mag_x = Float(data.magneticField.x)
//                self.currentData.mag_y = Float(data.magneticField.y)
//                self.currentData.mag_z = Float(data.magneticField.z)
//                self.lock.unlock()
//            }
//        }
    }
    
    func stop() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
//        motionManager.stopMagnetometerUpdates()
    }
}

// Exported function for Wasm
// @_cdecl("read_imu_impl")
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
