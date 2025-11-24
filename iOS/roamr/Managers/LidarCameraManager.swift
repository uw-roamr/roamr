//
//  LidarCameraManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

// uses AVFoundation for lower level access of sensors
import Foundation

struct LidarCameraData {
    var timestamp: Double
    var image_height: Int32
    var image_width: Int32
}

class LidarCameraManager {
    static let shared = LidarCameraManager()

    let lock = NSLock()

    var currentData = LidarCameraData(timestamp: 0, image_height: 0, image_width: 0)

    private init() {}
}

// exported function for Wasm
func read_lidar_camera_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

    let lidarCameraDataPtr = ptr.bindMemory(to: LidarCameraData.self, capacity: 1)

    let manager = LidarCameraManager.shared
    manager.lock.lock()
    let data = manager.currentData
    manager.lock.unlock()

    lidarCameraDataPtr.pointee = data
}
