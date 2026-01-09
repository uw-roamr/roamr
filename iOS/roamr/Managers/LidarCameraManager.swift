//
//  LidarCameraManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

// uses AVFoundation for lower level access of sensors
import Foundation
import AVFoundation

struct LidarCameraData {
    var timestamp: Double

    var depth_map: UnsafeMutableRawPointer?
    var depth_width: Int32
    var depth_height: Int32

    var image: UnsafeMutableRawPointer?
    var image_width: Int32
    var image_height: Int32
    var image_channels: Int32
}
// struct LidarCameraData {
//   double timestamp;

//   const float *depth_map;
//   int depth_width;
//   int depth_height;

//   const uint8_t *image;
//   int image_width;
//   int image_height;
//   int image_channels;
// };

class LidarCameraManager: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    static let shared = LidarCameraManager()

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let outputQueue = DispatchQueue(label: "com.roamr.lidar.camera.queue")

    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var currentVideoBuffer: CMSampleBuffer?
    private var currentDepthData: AVDepthData?

    var isDataDirty = false

    // choose an option that can provide depth: lidar, truedepth, or dual camera, fallback to back camera
    let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [
        .builtInLiDARDepthCamera,
        .builtInTrueDepthCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera
    ], mediaType: .video, position: .back)


    let lock = NSLock()

    var currentData = LidarCameraData(
        timestamp: 0, 
        depth_map: nil,
        depth_width: 0,
        depth_height: 0,
        image: nil,
        image_width: 0,
        image_height: 0, 
        image_channels: 0)

    private func startCapture(){
        videoOutput.alwaysDiscardsLateVideoFrames = true
        depthOutput.alwaysDiscardsLateDepthData = true

        captureSession.beginConfiguration()

        // inputs
        // at least one sensor should be available
        let lidarCameraDevices = self.discoverySession.devices
        guard !lidarCameraDevices.isEmpty else {fatalError("No compatible camera/lidar detected")}

        let backVideoDevice = lidarCameraDevices.first(where: {device in device.position == AVCaptureDevice.Position.back})!
        guard
            let backVideoDeviceInput = try? AVCaptureDeviceInput(device: backVideoDevice),
            captureSession.canAddInput(backVideoDeviceInput)
            else {return}
        captureSession.addInput(backVideoDeviceInput)

        // outputs
        guard captureSession.canAddOutput(videoOutput) else{return}
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        captureSession.addOutput(videoOutput)
        guard captureSession.canAddOutput(depthOutput) else {return}
        captureSession.addOutput(depthOutput)

        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        outputSynchronizer?.setDelegate(self, queue: outputQueue)

        captureSession.commitConfiguration()
        captureSession.startRunning()
    }

    func start(){
        switch AVCaptureDevice.authorizationStatus(for: .video){
        case .denied, .restricted:
            fatalError("Camera permission denied")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video){ granted in 
                guard granted else {return}
                DispatchQueue.main.async {
                    self.startCapture()
                }
            }
            return
        case .authorized:
            startCapture()
        @unknown default:
            break
        }
    }

    func stop(){
        captureSession.stopRunning()
    }

    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ){
        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData else {return}
        guard let synchedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData else {return}

        guard !syncedVideoData.sampleBufferWasDropped, !synchedDepthData.depthDataWasDropped else {return}

        let videoBuffer = syncedVideoData.sampleBuffer
        let depthData = synchedDepthData.depthData
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(videoBuffer))

        let imageBuffer = CMSampleBufferGetImageBuffer(videoBuffer)!
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        let depthMap = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)

        let imageBaseAddress = CVPixelBufferGetBaseAddress(imageBuffer)
        let imageWidth = CVPixelBufferGetWidth(imageBuffer)
        let imageHeight = CVPixelBufferGetHeight(imageBuffer)

        let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap)
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        lock.lock()
        self.currentVideoBuffer = videoBuffer
        self.currentDepthData = depthData

        currentData.timestamp = timestamp
        currentData.image = imageBaseAddress!
        currentData.image_width = Int32(imageWidth)
        currentData.image_height = Int32(imageHeight)
        currentData.image_channels = 4 // hardcoded to RGBA
        currentData.depth_map = depthBaseAddress!
        currentData.depth_width = Int32(depthWidth)
        currentData.depth_height = Int32(depthHeight)
        isDataDirty = true
        lock.unlock()
    }
}

// exported function for Wasm
func read_lidar_camera_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else {
        print("bad fn")
        return }

    let lidarCameraDataPtr = ptr.bindMemory(to: LidarCameraData.self, capacity: 1)

    let manager = LidarCameraManager.shared
    manager.lock.lock()
    guard manager.isDataDirty else{
        manager.lock.unlock()
        return
    }
    let data = manager.currentData
    manager.isDataDirty = false
    manager.lock.unlock()

    lidarCameraDataPtr.pointee = data
}
