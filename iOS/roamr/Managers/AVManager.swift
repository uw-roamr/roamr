//
//  AVManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

import Foundation
import ARKit
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

// Equivalent to C++ constants.
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

final class AVManager: NSObject, ObservableObject, ARSessionDelegate {
    static let shared = AVManager()

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

    private let session = ARSession()
    private let sessionQueue = DispatchQueue(label: "com.roamr.arkit.session", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.roamr.arkit.processing", qos: .userInitiated)
    private let ciContext = CIContext(options: nil)

    private var currentFrame: ARFrame?
    private var hasNewFrame = false
    private var isProcessingFrame = false

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
        image_frame_id: CoordinateFrameId.RDF.rawValue
    )

    private struct RGBFrameData {
        let rawBytes: [UInt8]
        let rawWidth: Int
        let rawHeight: Int

        let portraitBytes: [UInt8]
        let portraitWidth: Int
        let portraitHeight: Int

        let uiImage: UIImage?
    }

    private override init() {
        super.init()
        session.delegate = self
    }

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

    // MARK: - Session Control

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            DispatchQueue.main.async {
                self.isActive = false
            }
            print("ARWorldTrackingConfiguration is not supported on this device")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.isActive = false
            }
            print("Camera permission denied")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else {
                    DispatchQueue.main.async {
                        self.isActive = false
                    }
                    return
                }
                self.sessionQueue.async {
                    self.runSession()
                }
            }
        case .authorized:
            sessionQueue.async {
                self.runSession()
            }
        @unknown default:
            break
        }
    }

    func stop() {
        sessionQueue.async {
            self.session.pause()

            self.lock.lock()
            self.currentFrame = nil
            self.hasNewFrame = false
            self.isProcessingFrame = false
            self.lock.unlock()

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

    private func runSession() {
        var semantics = ARConfiguration.FrameSemantics()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            semantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        }

        guard !semantics.isEmpty else {
            print("Scene depth is not supported on this device")
            DispatchQueue.main.async {
                self.isActive = false
            }
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = semantics
        configuration.worldAlignment = .gravity

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        DispatchQueue.main.async {
            self.isActive = true
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

        // Throttle frame rate.
        if currentTime - lastStreamTime < frameInterval {
            return
        }
        lastStreamTime = currentTime

        // Update FPS counter.
        streamFrameCount += 1
        if currentTime - lastFPSUpdateTime >= 1.0 {
            DispatchQueue.main.async {
                self.streamFPS = Double(self.streamFrameCount)
            }
            streamFrameCount = 0
            lastFPSUpdateTime = currentTime
        }

        // Encode to JPEG and broadcast.
        if let jpegData = image.jpegData(compressionQuality: streamJpegQuality) {
            WebSocketManager.shared.broadcastBinaryData(jpegData)
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock()
        currentFrame = frame
        hasNewFrame = true
        let shouldStartProcessing = !isProcessingFrame
        if shouldStartProcessing {
            isProcessingFrame = true
        }
        lock.unlock()

        guard shouldStartProcessing else { return }

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            while true {
                var shouldExit = false
                autoreleasepool {
                    self.lock.lock()
                    let localFrame = self.currentFrame
                    self.hasNewFrame = false
                    self.lock.unlock()

                    guard let localFrame = localFrame else {
                        shouldExit = true
                        return
                    }

                    self.processFrame(localFrame)

                    self.lock.lock()
                    let shouldContinue = self.hasNewFrame
                    if !shouldContinue {
                        self.isProcessingFrame = false
                    }
                    self.lock.unlock()

                    if !shouldContinue {
                        shouldExit = true
                    }
                }

                if shouldExit { break }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("ARSession failed: \(error)")
        DispatchQueue.main.async {
            self.isActive = false
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.isActive = false
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        sessionQueue.async {
            self.runSession()
        }
    }

    // MARK: - Frame Processing

    private func processFrame(_ frame: ARFrame) {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        guard let rgbFrameData = rgbFrameData(from: frame.capturedImage) else { return }

        let pointCloudData = depthDataToPointCloud(
            depthMap: depthData.depthMap,
            confidenceMap: depthData.confidenceMap,
            frame: frame,
            colorRGB: rgbFrameData.rawBytes,
            colorWidth: rgbFrameData.rawWidth,
            colorHeight: rgbFrameData.rawHeight
        )

        let depthPixelData = depthDataToPixels(
            depthMap: depthData.depthMap,
            outputWidth: rgbFrameData.portraitWidth,
            outputHeight: rgbFrameData.portraitHeight
        )

        let depthImage = depthMapToUIImage(depthMap: depthData.depthMap)
        let camImage = rgbFrameData.uiImage

        if let image = camImage {
            streamFrame(image: image)
        }

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

                let colorIndex = i * LidarCameraConstants.colorsPerPoint
                if colorIndex + 2 < pointCloudData.colors.count {
                    colorsBytes.append(pointCloudData.colors[colorIndex])
                    colorsBytes.append(pointCloudData.colors[colorIndex + 1])
                    colorsBytes.append(pointCloudData.colors[colorIndex + 2])
                }

                i += sampleStride
                written += 1
            }
        }

        DispatchQueue.main.async {
            self.depthMapImage = depthImage
            self.cameraImage = camImage
            self.pointCloud = pointCloudData
            self.depthPixels = depthPixelData
        }

        lock.lock()
        currentImageWidth = Int32(rgbFrameData.portraitWidth)
        currentImageHeight = Int32(rgbFrameData.portraitHeight)
        currentImageChannels = 3

        currentData = LidarCameraData(
            timestamp: frame.timestamp,
            points: pointsFloats,
            points_size: Int32(pointsFloats.count),
            colors: colorsBytes,
            colors_size: Int32(colorsBytes.count),
            image: rgbFrameData.portraitBytes,
            image_size: Int32(rgbFrameData.portraitBytes.count),
            points_frame_id: CoordinateFrameId.FLU.rawValue,
            image_frame_id: CoordinateFrameId.RDF.rawValue
        )
        isDataDirty = true
        lock.unlock()
    }

    // MARK: - Camera / Image Conversion

    private func rgbFrameData(from pixelBuffer: CVPixelBuffer) -> RGBFrameData? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let cgImage = ciContext.createCGImage(ciImage, from: rect) else {
            return nil
        }

        var rgbaBytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgbaBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: rect)

        var rgbBytes = [UInt8](repeating: 0, count: width * height * 3)
        var srcIndex = 0
        var dstIndex = 0
        while srcIndex + 3 < rgbaBytes.count {
            rgbBytes[dstIndex] = rgbaBytes[srcIndex]
            rgbBytes[dstIndex + 1] = rgbaBytes[srcIndex + 1]
            rgbBytes[dstIndex + 2] = rgbaBytes[srcIndex + 2]
            srcIndex += 4
            dstIndex += 3
        }

        let layout = portraitLayout(width: width, height: height)
        let portraitBytes: [UInt8]
        if layout.rotate {
            portraitBytes = rotateBytes90CW(rgbBytes, width: width, height: height, channels: 3)
        } else {
            portraitBytes = rgbBytes
        }

        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: layout.rotate ? .right : .up)

        return RGBFrameData(
            rawBytes: rgbBytes,
            rawWidth: width,
            rawHeight: height,
            portraitBytes: portraitBytes,
            portraitWidth: layout.width,
            portraitHeight: layout.height,
            uiImage: uiImage
        )
    }

    // MARK: - Depth Conversion

    private func depthDataToPixels(depthMap: CVPixelBuffer, outputWidth: Int, outputHeight: Int) -> DepthPixelData? {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        let layout = portraitLayout(width: width, height: height)
        let scaleX = Float(outputWidth) / Float(max(1, layout.width))
        let scaleY = Float(outputHeight) / Float(max(1, layout.height))

        var pixels: [(x: Int, y: Int, depth: Float)] = []
        pixels.reserveCapacity(width * height / 4)

        for y in 0..<height {
            let rowPtr = depthPointer.advanced(by: y * stride)
            for x in 0..<width {
                let depth = rowPtr[x]
                guard depth > 0, depth.isFinite else { continue }

                let px: Int
                let py: Int
                if layout.rotate {
                    px = height - 1 - y
                    py = x
                } else {
                    px = x
                    py = y
                }

                let mappedX = min(outputWidth - 1, max(0, Int(round(Float(px) * scaleX))))
                let mappedY = min(outputHeight - 1, max(0, Int(round(Float(py) * scaleY))))
                pixels.append((x: mappedX, y: mappedY, depth: depth))
            }
        }

        return DepthPixelData(
            pixels: pixels,
            width: outputWidth,
            height: outputHeight,
            count: pixels.count
        )
    }

    private func depthDataToPointCloud(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        frame: ARFrame,
        colorRGB: [UInt8],
        colorWidth: Int,
        colorHeight: Int
    ) -> PointCloudData? {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let depthPointer = depthBaseAddress.assumingMemoryBound(to: Float32.self)

        var confidencePointer: UnsafeMutablePointer<UInt8>?
        var confidenceStride = 0
        if let confidenceMap = confidenceMap,
           CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8 {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            confidencePointer = CVPixelBufferGetBaseAddress(confidenceMap)?.assumingMemoryBound(to: UInt8.self)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        let minimumConfidence = UInt8(ARConfidenceLevel.medium.rawValue)

        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        let imageResolution = frame.camera.imageResolution
        let intrinsicsScaleX = Float(imageResolution.width) / Float(max(1, depthWidth))
        let intrinsicsScaleY = Float(imageResolution.height) / Float(max(1, depthHeight))

        let colorScaleX = Float(colorWidth) / Float(max(1, depthWidth))
        let colorScaleY = Float(colorHeight) / Float(max(1, depthHeight))

        let pointStride = max(1, LidarCameraConstants.pointSubsampleStride)
        let estimatedPoints = max(1, (depthWidth * depthHeight) / pointStride)

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(estimatedPoints)

        var colors: [UInt8] = []
        colors.reserveCapacity(estimatedPoints * LidarCameraConstants.colorsPerPoint)

        for y in 0..<depthHeight {
            let depthRowPtr = depthPointer.advanced(by: y * depthStride)
            let confidenceRowPtr = confidencePointer?.advanced(by: y * confidenceStride)

            let startX = y % pointStride
            var x = startX
            while x < depthWidth {
                defer { x += pointStride }

                let depth = depthRowPtr[x]
                guard depth > 0, depth.isFinite else { continue }

                if let confidenceRowPtr = confidenceRowPtr {
                    // Keep medium/high confidence samples.
                    let confidence = confidenceRowPtr[x]
                    guard confidence >= minimumConfidence else { continue }
                }

                let imageU = (Float(x) + 0.5) * intrinsicsScaleX
                let imageV = (Float(y) + 0.5) * intrinsicsScaleY

                let cameraX = (imageU - cx) * depth / fx
                let cameraY = (imageV - cy) * depth / fy

                let pointRdf = SIMD3<Float>(cameraX, cameraY, depth)
                let pointFlu = CoordinateFrames.cameraRdfToFlu(pointRdf)
                points.append(pointFlu)

                let colorX = min(colorWidth - 1, max(0, Int(round(Float(x) * colorScaleX))))
                let colorY = min(colorHeight - 1, max(0, Int(round(Float(y) * colorScaleY))))
                let colorIndex = (colorY * colorWidth + colorX) * LidarCameraConstants.colorsPerPoint

                if colorIndex + 2 < colorRGB.count {
                    colors.append(colorRGB[colorIndex])
                    colors.append(colorRGB[colorIndex + 1])
                    colors.append(colorRGB[colorIndex + 2])
                }
            }
        }

        return PointCloudData(points: points, colors: colors, count: points.count)
    }

    private func depthMapToUIImage(depthMap: CVPixelBuffer) -> UIImage? {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)

        var minDepth: Float = .infinity
        var maxDepth: Float = 0

        for y in 0..<height {
            let rowPtr = depthPointer.advanced(by: y * stride)
            for x in 0..<width {
                let d = rowPtr[x]
                guard d.isFinite, d > 0 else { continue }
                minDepth = min(minDepth, d)
                maxDepth = max(maxDepth, d)
            }
        }

        guard minDepth.isFinite, maxDepth > minDepth else {
            return nil
        }

        var grayscale = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            let rowPtr = depthPointer.advanced(by: y * stride)
            for x in 0..<width {
                let index = y * width + x
                let d = rowPtr[x]
                guard d.isFinite, d > 0 else {
                    grayscale[index] = 0
                    continue
                }

                let normalized = 1.0 - ((d - minDepth) / (maxDepth - minDepth))
                grayscale[index] = UInt8(max(0, min(1, normalized)) * 255)
            }
        }

        let layout = portraitLayout(width: width, height: height)
        let outputBytes: [UInt8]
        let outputWidth: Int
        let outputHeight: Int

        if layout.rotate {
            outputBytes = rotateBytes90CW(grayscale, width: width, height: height, channels: 1)
            outputWidth = layout.width
            outputHeight = layout.height
        } else {
            outputBytes = grayscale
            outputWidth = width
            outputHeight = height
        }

        var mutableBytes = outputBytes
        guard let context = CGContext(
            data: &mutableBytes,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }
}

// MARK: - WASM export functions

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
