//
//  AVManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

// uses AVFoundation for lower level access of sensors
import Foundation
import AVFoundation
import Combine
import UIKit

struct LidarCameraInitData {
	var timestamp: Double
	var image_width: Int32
	var image_height: Int32
	var image_channels: Int32
}
struct LidarCameraData {
    var timestamp: Double

    var points: [Float32]
    var points_size: Int32

    var image: [Float32]
    var image_size: Int32
}

struct PointCloudData {
    var points: [SIMD3<Float>]  // 3D world coordinates (meters)
    var count: Int
}

struct DepthPixelData {
    var pixels: [(x: Int, y: Int, depth: Float)]  // Pixel coords + depth for visualization
    var width: Int
    var height: Int
    var count: Int
}

class AVManager: NSObject, ObservableObject, AVCaptureDataOutputSynchronizerDelegate {
    static let shared = AVManager()
    static var firstCapture = true

    @Published var isActive = false
    @Published var depthMapImage: UIImage?
    @Published var cameraImage: UIImage?
    @Published var pointCloud: PointCloudData?
    @Published var depthPixels: DepthPixelData?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let outputQueue = DispatchQueue(label: "com.roamr.lidar.camera.queue")

    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var currentVideoBuffer: CMSampleBuffer?
    private var currentDepthData: AVDepthData?

    var isDataDirty = false

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

    private func startCapture() {
        // Stop any existing session
        if captureSession.isRunning {
            print("⚠️ Session already running, stopping it first...")
            captureSession.stopRunning()
        }

        // Remove any existing inputs/outputs
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        captureSession.beginConfiguration()

        // Find LiDAR camera device
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInLiDARDepthCamera],
            mediaType: .video,
            position: .back
        )

        guard let device = discoverySession.devices.first else {
            print("❌ No LiDAR camera found")
            captureSession.commitConfiguration()
            return
        }

        // Add device input
        guard let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            print("❌ Cannot add device input")
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        // IMPORTANT: Set preset AFTER adding input
        // Use .inputPriority when manually configuring device formats
        if captureSession.canSetSessionPreset(.inputPriority) {
            captureSession.sessionPreset = .inputPriority
            print("✅ Set session preset to inputPriority")
        } else {
            print("⚠️ Cannot set inputPriority preset")
        }

        // Configure device format
        do {
            try device.lockForConfiguration()

            // Target resolutions (set to 0 to use largest available)
            let targetVideoWidth: Int32 = 1920
            let targetVideoHeight: Int32 = 1440
            let targetDepthWidth: Int32 = 1920
            let targetDepthHeight: Int32 = 1440

            // Find a format with depth support matching target size
            let formatsWithDepth = device.formats.filter { format in
                !format.supportedDepthDataFormats.isEmpty &&
                format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 })
            }

            // Sort by how close to target resolution (or largest if target is 0)
            let sortedFormats = formatsWithDepth.sorted { a, b in
                let dimsA = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let dimsB = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                if targetVideoWidth == 0 {
                    return dimsA.width * dimsA.height > dimsB.width * dimsB.height
                }
                let diffA = abs(dimsA.width - targetVideoWidth) + abs(dimsA.height - targetVideoHeight)
                let diffB = abs(dimsB.width - targetVideoWidth) + abs(dimsB.height - targetVideoHeight)
                return diffA < diffB
            }

            if let format = sortedFormats.first {
                device.activeFormat = format

                // Find best matching depth format
                let sortedDepthFormats = format.supportedDepthDataFormats.sorted { a, b in
                    let dimsA = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                    let dimsB = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                    if targetDepthWidth == 0 {
                        return dimsA.width * dimsA.height > dimsB.width * dimsB.height
                    }
                    let diffA = abs(dimsA.width - targetDepthWidth) + abs(dimsA.height - targetDepthHeight)
                    let diffB = abs(dimsB.width - targetDepthWidth) + abs(dimsB.height - targetDepthHeight)
                    return diffA < diffB
                }

                if let depthFormat = sortedDepthFormats.first {
                    device.activeDepthDataFormat = depthFormat
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let depthDims = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
                    print("✅ Set format: video \(dims.width)x\(dims.height), depth \(depthDims.width)x\(depthDims.height)")
                }
            } else {
                print("⚠️ No suitable format with depth found, using default")
            }

            device.unlockForConfiguration()
        } catch {
            print("❌ Error configuring device: \(error)")
        }

        // Configure video output
		
//		print(videoOutput.availableVideoPixelFormatTypes)
		
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        guard captureSession.canAddOutput(videoOutput) else {
            print("❌ Cannot add video output")
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(videoOutput)

        // Configure depth output
        depthOutput.isFilteringEnabled = false
        depthOutput.alwaysDiscardsLateDepthData = true

        guard captureSession.canAddOutput(depthOutput) else {
            print("❌ Cannot add depth output")
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(depthOutput)

        // Set up synchronizer
        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        outputSynchronizer?.setDelegate(self, queue: outputQueue)

        captureSession.commitConfiguration()

        captureSession.startRunning()
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
			isActive = false
            print("❌ Camera permission denied")
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
					self.isActive = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.startCapture()
                    }
                }
            }
        case .authorized:
			self.isActive = true
            DispatchQueue.global(qos: .userInitiated).async {
                self.startCapture()
            }
        @unknown default:
            break
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.stopRunning()
            DispatchQueue.main.async {
                self.isActive = false
            }
        }
    }

    func toggleSession() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Depth Data Conversion

    func depthDataToPixels(depthData: AVDepthData) -> DepthPixelData? {
        let convertedDepthData: AVDepthData
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthData.depthDataMap)

        if pixelFormat == kCVPixelFormatType_DepthFloat16 || pixelFormat == kCVPixelFormatType_DisparityFloat16 {
            convertedDepthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        } else {
            convertedDepthData = depthData
        }

        let depthMap = convertedDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)

        var pixels: [(x: Int, y: Int, depth: Float)] = []
        pixels.reserveCapacity(width * height / 4)

        for y in 0..<height {
            for x in 0..<width {
                let depth = depthPointer[y * width + x]
                guard depth > 0 && depth.isFinite else { continue }
                pixels.append((x: x, y: y, depth: depth))
            }
        }

        return DepthPixelData(pixels: pixels, width: width, height: height, count: pixels.count)
    }

    func depthDataToPointCloud(depthData: AVDepthData) -> PointCloudData? {
        // Convert to Float32 if needed
        let convertedDepthData: AVDepthData
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthData.depthDataMap)

        if pixelFormat == kCVPixelFormatType_DepthFloat16 || pixelFormat == kCVPixelFormatType_DisparityFloat16 {
            convertedDepthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        } else {
            convertedDepthData = depthData
        }

        let depthMap = convertedDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)

        // Get camera intrinsics
        guard let calibration = convertedDepthData.cameraCalibrationData else {
            print("❌ No camera calibration data available")
            return nil
        }

        let intrinsics = calibration.intrinsicMatrix
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(width * height / 4)

        for y in 0..<height {
            for x in 0..<width {
                let depth = depthPointer[y * width + x]

                // Skip invalid depth values
                guard depth > 0 && depth.isFinite else { continue }

                // Unproject: pixel (x,y) + depth -> 3D point
                let xWorld = (Float(x) - cx) * depth / fx
                let yWorld = (Float(y) - cy) * depth / fy
                let zWorld = depth

                points.append(SIMD3<Float>(xWorld, yWorld, zWorld))
            }
        }

        return PointCloudData(points: points, count: points.count)
    }

    // MARK: - Image Conversion

    private func depthDataToUIImage(depthData: AVDepthData) -> UIImage? {
        // Convert to Float32 format if needed to ensure consistent processing
        let convertedDepthData: AVDepthData
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthData.depthDataMap)

        if pixelFormat == kCVPixelFormatType_DepthFloat16 || pixelFormat == kCVPixelFormatType_DisparityFloat16 {
            convertedDepthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        } else {
            convertedDepthData = depthData
        }

        let depthMap = convertedDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)

        // Find min/max for normalization
        var minDepth: Float = .infinity
        var maxDepth: Float = -.infinity

        for i in 0..<(width * height) {
            let depth = depthPointer[i]
            if depth.isFinite {
                minDepth = min(minDepth, depth)
                maxDepth = max(maxDepth, depth)
            }
        }

        // Create grayscale image
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        var grayscaleData = [UInt8](repeating: 0, count: width * height)

        for i in 0..<(width * height) {
            let depth = depthPointer[i]
            if depth.isFinite && maxDepth > minDepth {
                let normalized = 1.0 - (depth - minDepth) / (maxDepth - minDepth)
                grayscaleData[i] = UInt8(normalized * 255.0)
            }
        }

        guard let context = CGContext(
            data: &grayscaleData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ),
        let cgImage = context.makeImage() else { return nil }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    private func sampleBufferToUIImage(sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    // MARK: - Synchronizer Delegate

    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData else {
            return
        }

        guard !syncedVideoData.sampleBufferWasDropped,
              !syncedDepthData.depthDataWasDropped else {
            return
        }

        let videoBuffer = syncedVideoData.sampleBuffer
        let depthData = syncedDepthData.depthData
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(videoBuffer))

        // Generate point cloud and depth pixels for visualization
        let pointCloudData = depthDataToPointCloud(depthData: depthData)
        let depthPixelData = depthDataToPixels(depthData: depthData)

        guard let imageBuffer = CMSampleBufferGetImageBuffer(videoBuffer) else { return }

        // Lock buffers
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let depthMap = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let imageBaseAddress = CVPixelBufferGetBaseAddress(imageBuffer),
              let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return
        }

        let imageWidth = CVPixelBufferGetWidth(imageBuffer)
        let imageHeight = CVPixelBufferGetHeight(imageBuffer)
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        // Update current data for WASM
        lock.lock()
        currentVideoBuffer = videoBuffer
        currentDepthData = depthData
		currentData = LidarCameraData(
			timestamp: timestamp,
			depth_map: depthBaseAddress,
			depth_width: Int32(depthWidth),
			depth_height: Int32(depthHeight),
			image: imageBaseAddress,
			image_width: Int32(imageWidth),
			image_height: Int32(imageHeight),
			image_channels: 4)
        isDataDirty = true
        lock.unlock()

        // Generate UI images and point cloud
        let depthImage = depthDataToUIImage(depthData: depthData)
        let camImage = sampleBufferToUIImage(sampleBuffer: videoBuffer)

        DispatchQueue.main.async {
            self.depthMapImage = depthImage
            self.cameraImage = camImage
            self.pointCloud = pointCloudData
            self.depthPixels = depthPixelData
        }
    }
}

// WASM export functions
func init_lidar_camera_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

    let lidarCameraConfigPtr = ptr.bindMemory(to: LidarCameraData.self, capacity: 1)
    let manager = AVManager.shared

    while !manager.isActive {}
    // populate fields

    lidarCameraConfig.pointee = data
}

func read_lidar_camera_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

    let lidarCameraDataPtr = ptr.bindMemory(to: LidarCameraData.self, capacity: 1)
    let manager = AVManager.shared

    manager.lock.lock()
    guard manager.isDataDirty else {
        manager.lock.unlock()
        return
    }
    // update data
    

    manager.isDataDirty = false
    manager.lock.unlock()

    lidarCameraDataPtr.pointee = data
}
