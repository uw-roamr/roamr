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

struct PointCloudExportData {
    var points: [Float32]  // FLU frame packed as xyzxyz...
    var colors: [UInt8]    // RGB per point
    var pointCount: Int
}

enum AVPreviewMode {
    case none
    case video
    case depth
    case point
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

    // Keep compute cost bounded for WASM/Rerun telemetry.
    private let processingTargetFPS: Double = 20.0
    private let previewTargetFPS: Double = 12.0
    private let rgbDownsampleFactor: Int = 2
    private let depthPixelSubsampleStride: Int = 2
    private let includePointColorsForWasm: Bool = true
    private let includeImageInWasmPayload: Bool = false

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
    private var lastProcessedFrameTimestamp: TimeInterval = 0
    private var lastPreviewFrameTimestamp: TimeInterval = 0
    private var previewMode: AVPreviewMode = .none

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

    private struct RGBColorSource {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    private override init() {
        super.init()
        session.delegate = self
    }

    func setPreviewMode(_ mode: AVPreviewMode) {
        lock.lock()
        previewMode = mode
        if mode == .none {
            lastPreviewFrameTimestamp = 0
        }
        lock.unlock()

        if mode == .none {
            DispatchQueue.main.async {
                self.depthMapImage = nil
                self.cameraImage = nil
                self.pointCloud = nil
                self.depthPixels = nil
            }
        }
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
            self.lastProcessedFrameTimestamp = 0
            self.lastPreviewFrameTimestamp = 0
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
        let processInterval = 1.0 / processingTargetFPS
        if lastProcessedFrameTimestamp > 0,
           frame.timestamp - lastProcessedFrameTimestamp < processInterval {
            return
        }
        lastProcessedFrameTimestamp = frame.timestamp

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        lock.lock()
        let localPreviewMode = previewMode
        lock.unlock()

        let previewIsEnabled = localPreviewMode != .none
        let shouldUpdatePreview: Bool
        if previewIsEnabled {
            if lastPreviewFrameTimestamp == 0 {
                shouldUpdatePreview = true
                lastPreviewFrameTimestamp = frame.timestamp
            } else if frame.timestamp - lastPreviewFrameTimestamp >= (1.0 / previewTargetFPS) {
                shouldUpdatePreview = true
                lastPreviewFrameTimestamp = frame.timestamp
            } else {
                shouldUpdatePreview = false
            }
        } else {
            shouldUpdatePreview = false
        }

        let needsPreviewVideo = shouldUpdatePreview && localPreviewMode == .video
        let needsPreviewDepth = shouldUpdatePreview && localPreviewMode == .depth
        let needsPreviewPoint = shouldUpdatePreview && localPreviewMode == .point
        let needsPointColors = includePointColorsForWasm
        let needsImagePayload = includeImageInWasmPayload
        let needsUIImage = needsPreviewVideo || isStreaming
        let needsRGBFrame = needsImagePayload || needsUIImage

        let imageResolution = frame.camera.imageResolution
        let fallbackLayout = portraitLayout(
            width: Int(imageResolution.width),
            height: Int(imageResolution.height)
        )

        let rgbFrame: RGBFrameData?
        if needsRGBFrame {
            rgbFrame = rgbFrameData(
                from: frame.capturedImage,
                downsampleFactor: rgbDownsampleFactor,
                includeUIImage: needsUIImage,
                includePortraitBytes: needsImagePayload
            )
        } else {
            rgbFrame = nil
        }

        let pointCloudData = depthDataToPointCloud(
            depthMap: depthData.depthMap,
            confidenceMap: depthData.confidenceMap,
            frame: frame,
            colorSource: nil,
            colorPixelBuffer: needsPointColors ? frame.capturedImage : nil
        )

        if let image = rgbFrame?.uiImage {
            streamFrame(image: image)
        }

        if shouldUpdatePreview {
            let previewWidth = rgbFrame?.portraitWidth ?? fallbackLayout.width
            let previewHeight = rgbFrame?.portraitHeight ?? fallbackLayout.height

            let depthPixelData = needsPreviewPoint ? depthDataToPixels(
                depthMap: depthData.depthMap,
                outputWidth: previewWidth,
                outputHeight: previewHeight,
                sampleStride: depthPixelSubsampleStride
            ) : nil
            let depthImage = needsPreviewDepth ? depthMapToUIImage(depthMap: depthData.depthMap) : nil
            let camImage = needsPreviewVideo ? rgbFrame?.uiImage : nil

            DispatchQueue.main.async {
                self.depthMapImage = depthImage
                self.cameraImage = camImage
                self.pointCloud = nil
                self.depthPixels = depthPixelData
            }
        }

        lock.lock()
        currentImageWidth = Int32(rgbFrame?.portraitWidth ?? fallbackLayout.width)
        currentImageHeight = Int32(rgbFrame?.portraitHeight ?? fallbackLayout.height)
        currentImageChannels = 3

        let imageBytes = needsImagePayload ? (rgbFrame?.portraitBytes ?? []) : []
        currentData = LidarCameraData(
            timestamp: frame.timestamp,
            points: pointCloudData?.points ?? [],
            points_size: Int32((pointCloudData?.pointCount ?? 0) * LidarCameraConstants.floatsPerPoint),
            colors: pointCloudData?.colors ?? [],
            colors_size: Int32(pointCloudData?.colors.count ?? 0),
            image: imageBytes,
            image_size: Int32(imageBytes.count),
            points_frame_id: CoordinateFrameId.FLU.rawValue,
            image_frame_id: CoordinateFrameId.RDF.rawValue
        )
        isDataDirty = true
        lock.unlock()
    }

    // MARK: - Camera / Image Conversion

    private func rgbFrameData(
        from pixelBuffer: CVPixelBuffer,
        downsampleFactor: Int,
        includeUIImage: Bool,
        includePortraitBytes: Bool
    ) -> RGBFrameData? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let factor = max(1, downsampleFactor)
        let width = max(1, sourceWidth / factor)
        let height = max(1, sourceHeight / factor)

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        let outputRect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let cgImage = ciContext.createCGImage(ciImage, from: sourceRect) else {
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

        context.draw(cgImage, in: outputRect)

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
        if includePortraitBytes {
            if layout.rotate {
                portraitBytes = rotateBytes90CW(rgbBytes, width: width, height: height, channels: 3)
            } else {
                portraitBytes = rgbBytes
            }
        } else {
            portraitBytes = []
        }

        let uiImage: UIImage?
        if includeUIImage, let scaledCGImage = context.makeImage() {
            uiImage = UIImage(cgImage: scaledCGImage, scale: 1.0, orientation: layout.rotate ? .right : .up)
        } else {
            uiImage = nil
        }

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

    private func depthDataToPixels(
        depthMap: CVPixelBuffer,
        outputWidth: Int,
        outputHeight: Int,
        sampleStride: Int
    ) -> DepthPixelData? {
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
        let strideStep = max(1, sampleStride)

        var pixels: [(x: Int, y: Int, depth: Float)] = []
        pixels.reserveCapacity((width * height) / (strideStep * strideStep))

        for y in Swift.stride(from: 0, to: height, by: strideStep) {
            let rowPtr = depthPointer.advanced(by: y * stride)
            for x in Swift.stride(from: 0, to: width, by: strideStep) {
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
        colorSource: RGBColorSource?,
        colorPixelBuffer: CVPixelBuffer?
    ) -> PointCloudExportData? {
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

        let colorScaleX: Float
        let colorScaleY: Float
        if let colorSource = colorSource {
            colorScaleX = Float(colorSource.width) / Float(max(1, depthWidth))
            colorScaleY = Float(colorSource.height) / Float(max(1, depthHeight))
        } else {
            colorScaleX = 0
            colorScaleY = 0
        }

        var yPlanePointer: UnsafeMutablePointer<UInt8>?
        var yPlaneBytesPerRow = 0
        var yPlaneWidth = 0
        var yPlaneHeight = 0
        var uvPlanePointer: UnsafeMutablePointer<UInt8>?
        var uvPlaneBytesPerRow = 0
        var yuvFullRange = true

        if colorSource == nil, let colorPixelBuffer = colorPixelBuffer {
            let pixelFormat = CVPixelBufferGetPixelFormatType(colorPixelBuffer)
            let supportsYCbCr = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if supportsYCbCr, CVPixelBufferGetPlaneCount(colorPixelBuffer) >= 2 {
                CVPixelBufferLockBaseAddress(colorPixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(colorPixelBuffer, .readOnly) }
                yPlanePointer = CVPixelBufferGetBaseAddressOfPlane(colorPixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self)
                yPlaneBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorPixelBuffer, 0)
                yPlaneWidth = CVPixelBufferGetWidthOfPlane(colorPixelBuffer, 0)
                yPlaneHeight = CVPixelBufferGetHeightOfPlane(colorPixelBuffer, 0)
                uvPlanePointer = CVPixelBufferGetBaseAddressOfPlane(colorPixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self)
                uvPlaneBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorPixelBuffer, 1)
                yuvFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            }
        }

        let pointStride = max(1, LidarCameraConstants.pointSubsampleStride)
        let maxPointCount = LidarCameraConstants.maxPointsPerScan
        let estimatedPoints = min(maxPointCount, max(1, (depthWidth * depthHeight) / pointStride))
        let maxFloatCount = maxPointCount * LidarCameraConstants.floatsPerPoint
        let invFx = 1.0 as Float / fx
        let invFy = 1.0 as Float / fy
        let hasRgbColorSource = colorSource != nil
        let hasYuvColorSource = !hasRgbColorSource
            && yPlanePointer != nil
            && uvPlanePointer != nil
            && yPlaneWidth > 0
            && yPlaneHeight > 0

        var points = [Float32](
            repeating: 0,
            count: estimatedPoints * LidarCameraConstants.floatsPerPoint
        )
        var colors = [UInt8](
            repeating: 0,
            count: estimatedPoints * LidarCameraConstants.colorsPerPoint
        )

        var reachedPointLimit = false
        var pointCount = 0
        var colorCount = 0
        for y in 0..<depthHeight {
            if reachedPointLimit { break }
            let depthRowPtr = depthPointer.advanced(by: y * depthStride)
            let confidenceRowPtr = confidencePointer?.advanced(by: y * confidenceStride)

            let startX = y % pointStride
            var x = startX
            while x < depthWidth {
                let depth = depthRowPtr[x]
                guard depth > 0, depth.isFinite else {
                    x += pointStride
                    continue
                }

                if let confidenceRowPtr = confidenceRowPtr {
                    // Keep medium/high confidence samples.
                    let confidence = confidenceRowPtr[x]
                    guard confidence >= minimumConfidence else {
                        x += pointStride
                        continue
                    }
                }

                let imageU = (Float(x) + 0.5) * intrinsicsScaleX
                let imageV = (Float(y) + 0.5) * intrinsicsScaleY

                let cameraX = (imageU - cx) * depth * invFx
                let cameraY = (imageV - cy) * depth * invFy

                let outBase = pointCount * LidarCameraConstants.floatsPerPoint
                // RDF -> FLU: (x, y, z) -> (z, -x, -y)
                points[outBase + 0] = depth
                points[outBase + 1] = -cameraX
                points[outBase + 2] = -cameraY
                pointCount += 1

                if hasRgbColorSource, let colorSource = colorSource {
                    let colorX = min(colorSource.width - 1, max(0, Int(round(Float(x) * colorScaleX))))
                    let colorY = min(colorSource.height - 1, max(0, Int(round(Float(y) * colorScaleY))))
                    let colorIndex = (colorY * colorSource.width + colorX) * LidarCameraConstants.colorsPerPoint

                    let colorOutBase = colorCount * LidarCameraConstants.colorsPerPoint
                    if colorIndex + 2 < colorSource.bytes.count,
                       colorOutBase + 2 < colors.count {
                        colors[colorOutBase + 0] = colorSource.bytes[colorIndex]
                        colors[colorOutBase + 1] = colorSource.bytes[colorIndex + 1]
                        colors[colorOutBase + 2] = colorSource.bytes[colorIndex + 2]
                    }
                    colorCount += 1
                } else if hasYuvColorSource,
                          let yPlanePointer = yPlanePointer,
                          let uvPlanePointer = uvPlanePointer {
                    let colorX = min(yPlaneWidth - 1, max(0, Int(imageU.rounded())))
                    let colorY = min(yPlaneHeight - 1, max(0, Int(imageV.rounded())))
                    let yIndex = colorY * yPlaneBytesPerRow + colorX
                    let uvIndex = (colorY >> 1) * uvPlaneBytesPerRow + ((colorX >> 1) << 1)

                    let yValue = Float(yPlanePointer[yIndex])
                    let cbValue = Float(uvPlanePointer[uvIndex])
                    let crValue = Float(uvPlanePointer[uvIndex + 1])
                    let (r, g, b) = yCbCrToRgb(
                        y: yValue,
                        cb: cbValue,
                        cr: crValue,
                        fullRange: yuvFullRange
                    )
                    let colorOutBase = colorCount * LidarCameraConstants.colorsPerPoint
                    if colorOutBase + 2 < colors.count {
                        colors[colorOutBase + 0] = r
                        colors[colorOutBase + 1] = g
                        colors[colorOutBase + 2] = b
                    }
                    colorCount += 1
                }

                if pointCount * LidarCameraConstants.floatsPerPoint >= maxFloatCount
                    || pointCount >= estimatedPoints {
                    reachedPointLimit = true
                    break
                }
                x += pointStride
            }
        }

        let usedFloatCount = pointCount * LidarCameraConstants.floatsPerPoint
        if usedFloatCount < points.count {
            points.removeLast(points.count - usedFloatCount)
        }

        let usedColorCount = min(colorCount, pointCount) * LidarCameraConstants.colorsPerPoint
        if usedColorCount < colors.count {
            colors.removeLast(colors.count - usedColorCount)
        }

        return PointCloudExportData(points: points, colors: colors, pointCount: pointCount)
    }

    private func yCbCrToRgb(y: Float, cb: Float, cr: Float, fullRange: Bool) -> (UInt8, UInt8, UInt8) {
        let cbShift = cb - 128.0
        let crShift = cr - 128.0

        let red: Float
        let green: Float
        let blue: Float
        if fullRange {
            red = y + (1.4020 * crShift)
            green = y - (0.344136 * cbShift) - (0.714136 * crShift)
            blue = y + (1.7720 * cbShift)
        } else {
            let luma = max(0, y - 16.0) * 1.164383
            red = luma + (1.596027 * crShift)
            green = luma - (0.391762 * cbShift) - (0.812968 * crShift)
            blue = luma + (2.017232 * cbShift)
        }
        return (clampToUInt8(red), clampToUInt8(green), clampToUInt8(blue))
    }

    private func clampToUInt8(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(value.rounded()))))
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
