import Foundation
import CoreMotion

struct IMUData {
    var timestamp: Double
    var acc_x: Float
    var acc_y: Float
    var acc_z: Float
    var gyro_x: Float
    var gyro_y: Float
    var gyro_z: Float
    var mag_x: Float
    var mag_y: Float
    var mag_z: Float
}

class IMUManager {
    static let shared = IMUManager()
    
    private let motionManager = CMMotionManager()
    let lock = NSLock()
    var currentData = IMUData(timestamp: 0, acc_x: 0, acc_y: 0, acc_z: 0, gyro_x: 0, gyro_y: 0, gyro_z: 0, mag_x: 0, mag_y: 0, mag_z: 0)
    
    private init() {}
    
    func start() {
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.1
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] (data, error) in
                guard let self = self, let data = data else { return }
                self.lock.lock()
                self.currentData.timestamp = data.timestamp
                self.currentData.acc_x = Float(data.acceleration.x)
                self.currentData.acc_y = Float(data.acceleration.y)
                self.currentData.acc_z = Float(data.acceleration.z)
                self.lock.unlock()
            }
        }
        
        if motionManager.isGyroAvailable {
            motionManager.gyroUpdateInterval = 0.1
            motionManager.startGyroUpdates(to: .main) { [weak self] (data, error) in
                guard let self = self, let data = data else { return }
                self.lock.lock()
                self.currentData.gyro_x = Float(data.rotationRate.x)
                self.currentData.gyro_y = Float(data.rotationRate.y)
                self.currentData.gyro_z = Float(data.rotationRate.z)
                self.lock.unlock()
            }
        }
        
        if motionManager.isMagnetometerAvailable {
            motionManager.magnetometerUpdateInterval = 0.1
            motionManager.startMagnetometerUpdates(to: .main) { [weak self] (data, error) in
                guard let self = self, let data = data else { return }
                self.lock.lock()
                self.currentData.mag_x = Float(data.magneticField.x)
                self.currentData.mag_y = Float(data.magneticField.y)
                self.currentData.mag_z = Float(data.magneticField.z)
                self.lock.unlock()
            }
        }
    }
    
    func stop() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopMagnetometerUpdates()
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
