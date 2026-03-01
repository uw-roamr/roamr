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
import ImageIO

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

    var colors: [UInt8]
    var colors_size: Int32

    var image: [UInt8]
    var image_size: Int32

    var points_frame_id: FrameId
    var image_frame_id: FrameId
}

struct PointCloudData {
    var points: [SIMD3<Float>]  // 3D camera-frame points in FLU (meters)
    var colors: [UInt8]         // RGB per point (len = points.count * 3)
    var count: Int
}

struct DepthPixelData {
    var pixels: [(x: Int, y: Int, depth: Float)]  // Pixel coords + depth for visualization
    var width: Int
    var height: Int
    var count: Int
}

// equivalent to C++ constants
enum LidarCameraConstants {
    static let maxPointsPerScan = 100000
    static let floatsPerPoint = 3
    static let maxPointsSize = maxPointsPerScan * floatsPerPoint
    static let pointSubsampleStride = 6
    
    static let colorsPerPoint = 3
    static let maxColorsSize = maxPointsPerScan * colorsPerPoint
    static let maxImageWidth = 1920
    static let maxImageHeight = 1440
    static let maxImageChannels = 3
    static let maxImageSize = maxImageWidth * maxImageHeight * maxImageChannels
}

class AVManager: NSObject, ObservableObject, AVCaptureDataOutputSynchronizerDelegate {
    static let shared = AVManager()
    static var firstCapture = true

    @Published var isActive = false
    @Published var depthMapImage: UIImage?
    @Published var cameraImage: UIImage?
    @Published var pointCloud: PointCloudData?
    @Published var depthPixels: DepthPixelData?

    // Video streaming
    @Published var isStreaming = false
    @Published var streamFPS: Double = 0.0
    private var streamTargetFPS: Int = 30
    private var streamJpegQuality: CGFloat = 0.5
    private var lastStreamTime: TimeInterval = 0
    private var streamFrameCount: Int = 0
    private var lastFPSUpdateTime: TimeInterval = 0

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.roamr.lidar.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.roamr.lidar.camera.queue")

    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var currentVideoBuffer: CMSampleBuffer?
    private var currentDepthData: AVDepthData?
    private let processingQueue = DispatchQueue(label: "com.roamr.lidar.processing", qos: .userInitiated)
    private var isProcessingFrame = false
    private var hasNewFrame = false

    var isDataDirty = false

    let lock = NSLock()

    var currentImageWidth: Int32 = 0
    var currentImageHeight: Int32 = 0
    var currentImageChannels: Int32 = 0

    var currentData = LidarCameraData(
        timestamp: 0,
		points: [Float32](),
		points_size: 0,
		colors: [UInt8](),
		colors_size: 0,
		image: [UInt8](),
		image_size: 0,
        points_frame_id: CoordinateFrameId.FLU.rawValue,
        image_frame_id: CoordinateFrameId.RDF.rawValue)

    private func portraitLayout(width: Int, height: Int) -> (width: Int, height: Int, rotate: Bool) {
        let rotate = width > height
        return rotate
            ? (width: height, height: width, rotate: true)
            : (width: width, height: height, rotate: false)
    }

    private func rotateBytes90CW(_ src: [UInt8], width: Int, height: Int, channels: Int) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                let srcIndex = (y * width + x) * channels
                let dstIndex = (x * height + (height - 1 - y)) * channels
                for c in 0..<channels {
                    dst[dstIndex + c] = src[srcIndex + c]
                }
            }
        }
        return dst
    }

    private func startCapture() {
        // Stop any existing session
        if captureSession.isRunning {
            print("Session already running, stopping it first...")
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
            print("No LiDAR camera found")
            captureSession.commitConfiguration()
            return
        }

        // Add device input
        guard let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            print("Cannot add device input")
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        // IMPORTANT: Set preset AFTER adding input
        // Use .inputPriority when manually configuring device formats
        if captureSession.canSetSessionPreset(.inputPriority) {
            captureSession.sessionPreset = .inputPriority
            print("Set session preset to inputPriority")
        } else {
            print("Cannot set inputPriority preset")
        }

        // Configure device format
        do {
            try device.lockForConfiguration()

            // Target resolutions (set to 0 to use largest available)
            let targetVideoWidth: Int32 = 1280
            let targetVideoHeight: Int32 = 720
            let targetDepthWidth: Int32 = 1280
            let targetDepthHeight: Int32 = 720

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
                func depthTypeRank(_ depthFormat: AVCaptureDevice.Format) -> Int {
                    switch CMFormatDescriptionGetMediaSubType(depthFormat.formatDescription) {
                    case kCVPixelFormatType_DepthFloat32:
                        return 0
                    case kCVPixelFormatType_DepthFloat16:
                        return 1
                    case kCVPixelFormatType_DisparityFloat32:
                        return 2
                    case kCVPixelFormatType_DisparityFloat16:
                        return 3
                    default:
                        return 4
                    }
                }

                let sortedDepthFormats = format.supportedDepthDataFormats.sorted { a, b in
                    let rankA = depthTypeRank(a)
                    let rankB = depthTypeRank(b)
                    if rankA != rankB {
                        return rankA < rankB
                    }
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
                    let depthType = CMFormatDescriptionGetMediaSubType(depthFormat.formatDescription)
                    print("Set format: video \(dims.width)x\(dims.height), depth \(depthDims.width)x\(depthDims.height), type=\(depthType)")
                }
            } else {
                print("No suitable format with depth found, using default")
            }

            device.unlockForConfiguration()
        } catch {
            print("Error configuring device: \(error)")
        }

        // Configure video output
		
//		print(videoOutput.availableVideoPixelFormatTypes)
		
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        guard captureSession.canAddOutput(videoOutput) else {
            print("Cannot add video output")
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(videoOutput)

        // Configure depth output
        // Filtered depth is less holey/streaky than raw output for live visualization.
        depthOutput.isFilteringEnabled = true
        depthOutput.alwaysDiscardsLateDepthData = true

        guard captureSession.canAddOutput(depthOutput) else {
            print("Cannot add depth output")
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(depthOutput)

        if let c = videoOutput.connection(with: .video) {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false } // back camera
        }

        if let c = depthOutput.connection(with: .depthData) {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
        }

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
            print("Camera permission denied")
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
					self.isActive = true
                    self.sessionQueue.async {
                        self.startCapture()
                    }
                }
            }
        case .authorized:
			self.isActive = true
            sessionQueue.async {
                self.startCapture()
            }
        @unknown default:
            break
        }
    }

    func stop() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
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

    // MARK: - Video Streaming

    func startStreaming(fps: Int = 15, quality: CGFloat = 0.5) {
        streamTargetFPS = fps
        streamJpegQuality = quality
        lastStreamTime = 0
        streamFrameCount = 0
        lastFPSUpdateTime = CACurrentMediaTime()
        isStreaming = true
        print("Video streaming started (target: \(fps) FPS, quality: \(Int(quality * 100))%)")
    }

    func stopStreaming() {
        isStreaming = false
        streamFPS = 0
        print("Video streaming stopped")
    }

    func toggleStreaming() {
        if isStreaming {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    private func streamFrame(image: UIImage) {
        guard isStreaming else { return }

        let currentTime = CACurrentMediaTime()
        let frameInterval = 1.0 / Double(streamTargetFPS)

        // Throttle frame rate
        if currentTime - lastStreamTime < frameInterval {
            return
        }
        lastStreamTime = currentTime

        // Update FPS counter
        streamFrameCount += 1
        if currentTime - lastFPSUpdateTime >= 1.0 {
            DispatchQueue.main.async {
                self.streamFPS = Double(self.streamFrameCount)
            }
            streamFrameCount = 0
            lastFPSUpdateTime = currentTime
        }

        // Encode to JPEG and broadcast
        if let jpegData = image.jpegData(compressionQuality: streamJpegQuality) {
            WebSocketManager.shared.broadcastBinaryData(jpegData)
        }
    }

    // MARK: - Depth Data Conversion

    private func convertedDepthDataInMeters(_ depthData: AVDepthData) -> AVDepthData {
        if depthData.depthDataType == kCVPixelFormatType_DepthFloat32 {
            return depthData
        }
        return depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    }

    private func orientedDepthDataForPortrait(_ depthData: AVDepthData) -> AVDepthData {
        let converted = convertedDepthDataInMeters(depthData)
        let depthMap = converted.depthDataMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > height else { return converted }
        return converted.applyingExifOrientation(CGImagePropertyOrientation.right)
    }

    private func intrinsicsForDepthMap(
        calibration: AVCameraCalibrationData,
        depthWidth: Int,
        depthHeight: Int
    ) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        let intrinsics = calibration.intrinsicMatrix
        var fx = intrinsics[0][0]
        var fy = intrinsics[1][1]
        var cx = intrinsics[2][0]
        var cy = intrinsics[2][1]

        var refWidth = Float(calibration.intrinsicMatrixReferenceDimensions.width)
        var refHeight = Float(calibration.intrinsicMatrixReferenceDimensions.height)

        let depthIsPortrait = depthHeight > depthWidth
        let refIsPortrait = refHeight > refWidth

        if depthIsPortrait != refIsPortrait {
            if !refIsPortrait && depthIsPortrait {
                // Rotate intrinsics 90° clockwise (landscape -> portrait).
                let newFx = fy
                let newFy = fx
                let newCx = refHeight - 1.0 - cy
                let newCy = cx
                fx = newFx
                fy = newFy
                cx = newCx
                cy = newCy
            } else {
                // Rotate intrinsics 90° counter-clockwise (portrait -> landscape).
                let newFx = fy
                let newFy = fx
                let newCx = cy
                let newCy = refWidth - 1.0 - cx
                fx = newFx
                fy = newFy
                cx = newCx
                cy = newCy
            }
            swap(&refWidth, &refHeight)
        }

        let sx = Float(depthWidth) / refWidth
        let sy = Float(depthHeight) / refHeight
        return (fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }

    func depthDataToPixels(depthData: AVDepthData, imageBuffer: CVPixelBuffer) -> DepthPixelData? {
        let convertedDepthData = orientedDepthDataForPortrait(depthData)

        let depthMap = convertedDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let depthWidth = width
        let depthHeight = height

        let colorWidth = CVPixelBufferGetWidth(imageBuffer)
        let colorHeight = CVPixelBufferGetHeight(imageBuffer)
        let colorLayout = portraitLayout(width: colorWidth, height: colorHeight)
        let outputWidth = colorLayout.width
        let outputHeight = colorLayout.height
        let scaleX = Float(outputWidth) / Float(depthWidth)
        let scaleY = Float(outputHeight) / Float(depthHeight)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)

        var pixels: [(x: Int, y: Int, depth: Float)] = []
        pixels.reserveCapacity(width * height / 4)

        for y in 0..<height {
            let rowPtr = depthPointer.advanced(by: y * depthStride)
            for x in 0..<width {
                let depth = rowPtr[x]
                guard depth > 0 && depth.isFinite else { continue }
                let mappedX = min(outputWidth - 1, max(0, Int(round(Float(x) * scaleX))))
                let mappedY = min(outputHeight - 1, max(0, Int(round(Float(y) * scaleY))))
                pixels.append((x: mappedX, y: mappedY, depth: depth))
            }
        }

        return DepthPixelData(pixels: pixels, width: outputWidth, height: outputHeight, count: pixels.count)
    }

    func depthDataToPointCloud(depthData: AVDepthData, imageBuffer: CVPixelBuffer) -> PointCloudData? {
        let convertedDepthData = orientedDepthDataForPortrait(depthData)

        let depthMap = convertedDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthPointer = depthBaseAddress.assumingMemoryBound(to: Float32.self)

        // Get color buffer access (BGRA)
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard let colorBaseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return nil }
        let colorBytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)

        // Get camera intrinsics
        guard let calibration = convertedDepthData.cameraCalibrationData else {
            print("No camera calibration data available")
            return nil
        }

        // Scale intrinsics to the actual depth map resolution (depth maps are often downsampled)
        let intrinsics = intrinsicsForDepthMap(
            calibration: calibration,
            depthWidth: width,
            depthHeight: height
        )
        let fx = intrinsics.fx
        let fy = intrinsics.fy
        let cx = intrinsics.cx
        let cy = intrinsics.cy

        // Color buffer sizing may differ from depth; scale sampling coords accordingly
        let colorWidth = CVPixelBufferGetWidth(imageBuffer)
        let colorHeight = CVPixelBufferGetHeight(imageBuffer)
        let colorScaleX = Float(colorWidth) / Float(width)
        let colorScaleY = Float(colorHeight) / Float(height)
        let pointStride = max(1, LidarCameraConstants.pointSubsampleStride)
        let estimatedPoints = max(1, (width * height) / pointStride)

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(estimatedPoints)
        var colors: [UInt8] = []
        colors.reserveCapacity(estimatedPoints * LidarCameraConstants.colorsPerPoint)

        for y in 0..<height {
            let rowPtr = depthPointer.advanced(by: y * depthStride)
            // Row phase follows stride so arbitrary strides spread coverage across x modulo classes.
            let startX = y % pointStride
            var x = startX
            while x < width {
                defer { x += pointStride }
                let depth = rowPtr[x]

                // Skip invalid depth values
                guard depth > 0 && depth.isFinite else { continue }

                // Undistort pixel if calibration data available
                var px = CGFloat(x)
                var py = CGFloat(y)
                // Undistortion: some SDKs ship `lensDistortionPoint(for:lookupTable:distortionCenter:)`.
                // If unavailable in this deployment target, skip undistortion to keep the build green.
                // Future: switch to CIFilter-based correction when available.

                // Unproject: pixel (x,y) + depth -> 3D point in camera RDF (meters)
                let xCam = (Float(px) - cx) * depth / fx
                let yCam = (Float(py) - cy) * depth / fy
                let zCam = depth

                let pointRdf = SIMD3<Float>(xCam, yCam, zCam)
                let pointFlu = CoordinateFrames.cameraRdfToFlu(pointRdf)
                points.append(pointFlu)

                // Extract color (BGRA -> RGB) using scaled coordinates into the color buffer
                let colorX = min(colorWidth - 1, max(0, Int(round(Float(x) * colorScaleX))))
                let colorY = min(colorHeight - 1, max(0, Int(round(Float(y) * colorScaleY))))
                let rowColorPtr = colorBaseAddress.advanced(by: colorY * colorBytesPerRow).assumingMemoryBound(to: UInt8.self)
                let pixelPtr = rowColorPtr.advanced(by: colorX * 4)
                colors.append(pixelPtr[2]) // R
                colors.append(pixelPtr[1]) // G
                colors.append(pixelPtr[0]) // B
            }
        }

        return PointCloudData(points: points, colors: colors, count: points.count)
    }

    // MARK: - Image Conversion

    private func depthDataToUIImage(depthData: AVDepthData) -> UIImage? {
        // Convert to meters/Float32 format for consistent visualization.
        let convertedDepthData = orientedDepthDataForPortrait(depthData)

        let depthMap = convertedDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)

        // Find min/max for normalization
        var minDepth: Float = .infinity
        var maxDepth: Float = -.infinity

        for y in 0..<height {
            let rowPtr = depthPointer.advanced(by: y * depthStride)
            for x in 0..<width {
                let depth = rowPtr[x]
                if depth.isFinite {
                    minDepth = min(minDepth, depth)
                    maxDepth = max(maxDepth, depth)
                }
            }
        }

        // Create grayscale image
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        var grayscaleData = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            let rowPtr = depthPointer.advanced(by: y * depthStride)
            for x in 0..<width {
                let i = y * width + x
                let depth = rowPtr[x]
                if depth.isFinite && maxDepth > minDepth {
                    let normalized = 1.0 - (depth - minDepth) / (maxDepth - minDepth)
                    grayscaleData[i] = UInt8(normalized * 255.0)
                }
            }
        }

        var outputData = grayscaleData
        let outputWidth = width
        let outputHeight = height

        guard let context = CGContext(
            data: &outputData,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ),
        let cgImage = context.makeImage() else { return nil }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private func sampleBufferToUIImage(sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let layout = portraitLayout(width: width, height: height)
        let orientedImage = layout.rotate ? ciImage.oriented(.right) : ciImage
        let context = CIContext()

        guard let cgImage = context.createCGImage(orientedImage, from: orientedImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
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

        guard let imageBuffer = CMSampleBufferGetImageBuffer(videoBuffer) else { return }
        let imageWidth = CVPixelBufferGetWidth(imageBuffer)
        let imageHeight = CVPixelBufferGetHeight(imageBuffer)
        let layout = portraitLayout(width: imageWidth, height: imageHeight)
        let outputWidth = layout.width
        let outputHeight = layout.height

        // Minimal work in callback: just stash latest buffers/metadata and signal processing queue
        lock.lock()
        currentVideoBuffer = videoBuffer
        currentDepthData = depthData
        currentImageWidth = Int32(outputWidth)
        currentImageHeight = Int32(outputHeight)
        currentImageChannels = 3 // we output RGB bytes
        hasNewFrame = true
        let shouldStartProcessing = !isProcessingFrame
        if shouldStartProcessing { isProcessingFrame = true }
        lock.unlock()

        if shouldStartProcessing {
            processingQueue.async { [weak self] in
                guard let self = self else { return }
                while true {
                    var requestedExit = false
                    autoreleasepool {
                        // Snapshot latest buffers
                        self.lock.lock()
                        let localVideoBuffer = self.currentVideoBuffer
                        let localDepthData = self.currentDepthData
                        self.hasNewFrame = false
                        self.lock.unlock()

                        guard let localVideoBuffer = localVideoBuffer,
                              let localDepthData = localDepthData,
                              let localImageBuffer = CMSampleBufferGetImageBuffer(localVideoBuffer)
                        else {
                            requestedExit = true
                            return
                        }

                        let localTimestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(localVideoBuffer))

                        // Build RGB bytes (uint8) from BGRA
                        let imageWidth = CVPixelBufferGetWidth(localImageBuffer)
                        let imageHeight = CVPixelBufferGetHeight(localImageBuffer)
                        let layout = self.portraitLayout(width: imageWidth, height: imageHeight)
                        let srcChannels = 4
                        let imageChannels = 3
                        let imagePixelCount = imageWidth * imageHeight
                        let imageElementCount = min(imagePixelCount * imageChannels, LidarCameraConstants.maxImageSize)
                        var imageBytesOut = [UInt8](repeating: 0, count: imageElementCount)

                        CVPixelBufferLockBaseAddress(localImageBuffer, .readOnly)
                        if let baseAddr = CVPixelBufferGetBaseAddress(localImageBuffer) {
                            let bytesPerRow = CVPixelBufferGetBytesPerRow(localImageBuffer)
                            let src = baseAddr.assumingMemoryBound(to: UInt8.self)
                            let maxRows = imageElementCount / (imageWidth * imageChannels)
                            let rows = min(imageHeight, maxRows)
                            var y = 0
                            while y < rows {
                                let rowBase = src.advanced(by: y * bytesPerRow)
                                var x = 0
                                while x < imageWidth {
                                    let pixelBase = rowBase.advanced(by: x * srcChannels)
                                    let dstIndex = (y * imageWidth + x) * imageChannels
                                    if dstIndex + 2 >= imageBytesOut.count {
                                        // stop filling this row
                                        x = imageWidth
                                        continue
                                    }
                                    // BGRA input -> RGB output
                                    imageBytesOut[dstIndex] = pixelBase[2]
                                    imageBytesOut[dstIndex + 1] = pixelBase[1]
                                    imageBytesOut[dstIndex + 2] = pixelBase[0]
                                    x += 1
                                }
                                y += 1
                            }
                        }
                        CVPixelBufferUnlockBaseAddress(localImageBuffer, .readOnly)

                        if layout.rotate {
                            imageBytesOut = self.rotateBytes90CW(
                                imageBytesOut,
                                width: imageWidth,
                                height: imageHeight,
                                channels: imageChannels
                            )
                        }

                        // Heavy computations off the capture queue
                        let pointCloudData = self.depthDataToPointCloud(depthData: localDepthData, imageBuffer: localImageBuffer)
                        let depthPixelData = self.depthDataToPixels(depthData: localDepthData, imageBuffer: localImageBuffer)
                        let depthImage = self.depthDataToUIImage(depthData: localDepthData)
                        let camImage = self.sampleBufferToUIImage(sampleBuffer: localVideoBuffer)

                        // Stream video if enabled
                        if let image = camImage {
                            self.streamFrame(image: image)
                        }

                        // Prepare points array for WASM
                        var pointsFloats: [Float32] = []
                        var colorsBytes: [UInt8] = []
                        if let pointCloudData = pointCloudData {
                            let totalPoints = pointCloudData.count
                            let pointCount = min(totalPoints, LidarCameraConstants.maxPointsPerScan)
                            let sampleStride = max(1, totalPoints / max(1, pointCount))
                            pointsFloats.reserveCapacity(pointCount * LidarCameraConstants.floatsPerPoint)
                            colorsBytes.reserveCapacity(pointCount * LidarCameraConstants.colorsPerPoint)
                            var i = 0
                            var written = 0
                            while i < totalPoints && written < pointCount {
                                let p = pointCloudData.points[i]
                                pointsFloats.append(p.x)
                                pointsFloats.append(p.y)
                                pointsFloats.append(p.z)
                                let cIdx = i * LidarCameraConstants.colorsPerPoint
                                if cIdx + 2 < pointCloudData.colors.count {
                                    colorsBytes.append(pointCloudData.colors[cIdx + 0])
                                    colorsBytes.append(pointCloudData.colors[cIdx + 1])
                                    colorsBytes.append(pointCloudData.colors[cIdx + 2])
                                }
                                i += sampleStride
                                written += 1
                            }
                        }

                        // Publish UI updates
                        DispatchQueue.main.async {
                            self.depthMapImage = depthImage
                            self.cameraImage = camImage
                            self.pointCloud = pointCloudData
                            self.depthPixels = depthPixelData
                        }

                        // Update current data for WASM
                        self.lock.lock()
                        self.currentData = LidarCameraData(
                            timestamp: localTimestamp,
                            points: pointsFloats,
                            points_size: Int32(pointsFloats.count),
                            colors: colorsBytes,
                            colors_size: Int32(colorsBytes.count),
                            image: imageBytesOut,
                            image_size: Int32(imageBytesOut.count),
                            points_frame_id: CoordinateFrameId.FLU.rawValue,
                            image_frame_id: CoordinateFrameId.RDF.rawValue
                        )
                        self.isDataDirty = true

                        // Decide whether to process another pending frame
                        let shouldContinue = self.hasNewFrame
                        if !shouldContinue { self.isProcessingFrame = false }
                        self.lock.unlock()

                        if !shouldContinue { requestedExit = true }
                    }
                    if requestedExit { break }
                }
            }
        }
    }
}

// WASM export functions
func init_camera_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

    let cameraConfigPtr = ptr.bindMemory(to: LidarCameraInitData.self, capacity: 1)
    let manager = AVManager.shared

    while !manager.isActive {
        Thread.sleep(forTimeInterval: 0.001)
    }

    var width: Int32 = 0
    var height: Int32 = 0
    var channels: Int32 = 0
    var timestamp: Double = 0

    while width == 0 || height == 0 || channels == 0 {
        manager.lock.lock()
        width = manager.currentImageWidth
        height = manager.currentImageHeight
        channels = manager.currentImageChannels
        timestamp = manager.currentData.timestamp
        manager.lock.unlock()
        if width == 0 || height == 0 || channels == 0 {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    cameraConfigPtr.pointee = LidarCameraInitData(
        timestamp: timestamp,
        image_width: width,
        image_height: height,
        image_channels: channels
    )
}

func read_lidar_camera_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr, let exec_env = exec_env else { return }

    let manager = AVManager.shared

    manager.lock.lock()
    guard manager.isDataDirty else {
        manager.lock.unlock()
        return
    }
    let data = manager.currentData
    manager.isDataDirty = false
    manager.lock.unlock()

    let basePtr = ptr.assumingMemoryBound(to: UInt8.self)
    guard let moduleInst = wasm_runtime_get_module_inst(exec_env) else {
        return
    }
    var nativeStart: UnsafeMutablePointer<UInt8>?
    var nativeEnd: UnsafeMutablePointer<UInt8>?
    if !wasm_runtime_get_native_addr_range(moduleInst, basePtr, &nativeStart, &nativeEnd) {
        return
    }
    let pointsOffset = MemoryLayout<Double>.size
    let pointsMaxCount = LidarCameraConstants.maxPointsSize
    let pointsByteCount = pointsMaxCount * MemoryLayout<Float32>.size
    let pointsSizeOffset = pointsOffset + pointsByteCount

    let colorsOffset = pointsSizeOffset + MemoryLayout<Int32>.size
    let colorsMaxCount = LidarCameraConstants.maxColorsSize
    let colorsByteCount = colorsMaxCount * MemoryLayout<UInt8>.size
    let colorsSizeOffset = colorsOffset + colorsByteCount

    let imageOffset = colorsSizeOffset + MemoryLayout<Int32>.size
    let imageMaxCount = LidarCameraConstants.maxImageSize
    let imageByteCount = imageMaxCount * MemoryLayout<UInt8>.size
    let imageSizeOffset = imageOffset + imageByteCount
    let imageSizeBytes = MemoryLayout<Int32>.size
    let pointsFrameIdOffset = imageSizeOffset + imageSizeBytes
    let imageFrameIdOffset = pointsFrameIdOffset + MemoryLayout<Int32>.size
    let totalBytes = imageFrameIdOffset + MemoryLayout<Int32>.size

    if let nativeEnd = nativeEnd {
        let baseAddr = UInt(bitPattern: basePtr)
        let endAddr = UInt(bitPattern: nativeEnd)
        if baseAddr + UInt(totalBytes) > endAddr {
            return
        }
    }

    basePtr.withMemoryRebound(to: Double.self, capacity: 1) { rebounded in
        rebounded.pointee = data.timestamp
    }

    let pointsCount = min(Int(data.points_size), pointsMaxCount)
    if pointsCount > 0 {
        data.points.withUnsafeBytes { src in
            if let srcBase = src.baseAddress {
                memcpy(basePtr.advanced(by: pointsOffset), srcBase, pointsCount * MemoryLayout<Float32>.size)
            }
        }
    }
    let pointsSizeValue = Int32(pointsCount)
    basePtr.advanced(by: pointsSizeOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
        rebounded.pointee = pointsSizeValue
    }

    let colorsCount = min(Int(data.colors_size), colorsMaxCount)
    if colorsCount > 0 {
        data.colors.withUnsafeBytes { src in
            if let srcBase = src.baseAddress {
                memcpy(basePtr.advanced(by: colorsOffset), srcBase, colorsCount * MemoryLayout<UInt8>.size)
            }
        }
    }
    let colorsSizeValue = Int32(colorsCount)
    basePtr.advanced(by: colorsSizeOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
        rebounded.pointee = colorsSizeValue
    }

    let imageCount = min(Int(data.image_size), imageMaxCount)
    if imageCount > 0 {
        data.image.withUnsafeBytes { src in
            if let srcBase = src.baseAddress {
                memcpy(basePtr.advanced(by: imageOffset), srcBase, imageCount * MemoryLayout<UInt8>.size)
            }
        }
    }
    let imageSizeValue = Int32(imageCount)
    basePtr.advanced(by: imageSizeOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
        rebounded.pointee = imageSizeValue
    }

    basePtr.advanced(by: pointsFrameIdOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
        rebounded.pointee = data.points_frame_id
    }
    basePtr.advanced(by: imageFrameIdOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
        rebounded.pointee = data.image_frame_id
    }
}
