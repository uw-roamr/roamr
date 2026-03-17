//
//  AVManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

import Foundation
import ARKit
import AVFoundation
import Accelerate
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

struct CameraImageFrame {
    var timestamp: Double
    var width: Int
    var height: Int
    var channels: Int
    var rgbBytes: [UInt8]
}

private struct RollingTimingStat {
    private(set) var totalSeconds: Double = 0
    private(set) var maxSeconds: Double = 0
    private(set) var sampleCount: Int = 0

    mutating func record(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        totalSeconds += seconds
        maxSeconds = max(maxSeconds, seconds)
        sampleCount += 1
    }

    var averageMilliseconds: Double {
        guard sampleCount > 0 else { return 0 }
        return (totalSeconds / Double(sampleCount)) * 1000.0
    }

    var maxMilliseconds: Double {
        maxSeconds * 1000.0
    }
}

private struct AVProfileContext {
    let hasWebSocketClients: Bool
    let isStreaming: Bool
    let previewMode: AVPreviewMode
    let hasActiveModels: Bool
}

private struct AVProfileWindow {
    var windowStartTime: CFTimeInterval = 0
    var receivedFrames: Int = 0
    var processedFrames: Int = 0
    var overwrittenFrames: Int = 0
    var throttledFrames: Int = 0
    var monitoredImageFrames: Int = 0
    var streamBypassedFrames: Int = 0

    var totalProcess = RollingTimingStat()
    var rgbConversion = RollingTimingStat()
    var rgbFormatDetect = RollingTimingStat()
    var rgbPixelBufferLock = RollingTimingStat()
    var rgbYCbCrConvert = RollingTimingStat()
    var rgbScaleRotate = RollingTimingStat()
    var rgbPack = RollingTimingStat()
    var rgbUIImage = RollingTimingStat()
    var wasmPointCloud = RollingTimingStat()
    var webSocketPointCloud = RollingTimingStat()
    var preview = RollingTimingStat()
    var jpegStream = RollingTimingStat()
    var stateUpdate = RollingTimingStat()
    var inferenceSubmit = RollingTimingStat()
    var rgbFallbackFrames: Int = 0

    mutating func reset(startTime: CFTimeInterval) {
        self = AVProfileWindow(windowStartTime: startTime)
    }
}

private struct RGBProfilingSample {
    var formatDetectSeconds: Double = 0
    var pixelBufferLockSeconds: Double = 0
    var yCbCrConvertSeconds: Double = 0
    var scaleRotateSeconds: Double = 0
    var packSeconds: Double = 0
    var uiImageSeconds: Double = 0
    var usedFallback = false
}

private struct StreamFrameRequest {
    let frame: CameraImageFrame
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
    static let pointSubsampleStride = 8

    static let colorsPerPoint = 3
    static let maxColorsSize = maxPointsPerScan * colorsPerPoint
    static let maxImageWidth = 1920
    static let maxImageHeight = 1440
    static let maxImageChannels = 3
    static let maxImageSize = maxImageWidth * maxImageHeight * maxImageChannels
}

final class AVManager: NSObject, ObservableObject, ARSessionDelegate {
    static let shared = AVManager()

    private struct StreamWorkerState {
        var generation: UInt64 = 0
        var pendingRequest: StreamFrameRequest?
        var isRunning = false
    }

    // Keep compute cost bounded for WASM/Rerun telemetry.
    private let processingTargetFPS: Double = 20.0
    private let previewTargetFPS: Double = 12.0
    private let websocketPointCloudTargetFPS: Double = 4.0
    private let inferenceTargetFPS: Double = 8.0
    private let rgbDownsampleFactor: Int = 2
    private let depthPixelSubsampleStride: Int = 2
    private let websocketPointCloudStride: Int = 16
    private let websocketPointCloudMaxPoints: Int = 6000
    private let enableAVProfiling = true
    private let profilingSummaryInterval: TimeInterval = 3.0
    private let includePointColorsForWasm: Bool = false
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
    private let streamStateQueue = DispatchQueue(label: "com.roamr.arkit.stream.state", qos: .userInitiated)
    private let streamExecutionQueue = DispatchQueue(label: "com.roamr.arkit.stream.execution", qos: .userInitiated)
    private let ciContext = CIContext(options: nil)
    private let profileLock = NSLock()
    private let renderColorSpace = CGColorSpaceCreateDeviceRGB()

    private var currentFrame: ARFrame?
    private var hasNewFrame = false
    private var isProcessingFrame = false
    private var lastProcessedFrameTimestamp: TimeInterval = 0
    private var lastPreviewFrameTimestamp: TimeInterval = 0
    private var lastWebSocketPointCloudTimestamp: TimeInterval = 0
    private var lastInferenceSubmissionTimestamp: TimeInterval = 0
    private var previewMode: AVPreviewMode = .none
    private var profileWindow = AVProfileWindow()
    private var fullResolutionARGBBytes: [UInt8] = []
    private var scaledARGBBytes: [UInt8] = []
    private var renderARGBBytes: [UInt8] = []
    private var packedRGBBytes: [UInt8] = []
    private var fallbackRGBABytes: [UInt8] = []
    private var streamWorkerState = StreamWorkerState()
    private var fullRangeYpCbCrToARGB = vImage_YpCbCrToARGB()
    private var videoRangeYpCbCrToARGB = vImage_YpCbCrToARGB()
    private var hasFullRangeYpCbCrToARGB = false
    private var hasVideoRangeYpCbCrToARGB = false

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
    private var latestCameraFrame: CameraImageFrame?

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

    private func resetWasmFrameStateLocked() {
        currentFrame = nil
        hasNewFrame = false
        isProcessingFrame = false
        lastProcessedFrameTimestamp = 0
        lastPreviewFrameTimestamp = 0
        lastWebSocketPointCloudTimestamp = 0
        lastInferenceSubmissionTimestamp = 0
        currentImageWidth = 0
        currentImageHeight = 0
        currentImageChannels = 0
        currentData = LidarCameraData(
            timestamp: 0,
            points: [],
            points_size: 0,
            colors: [],
            colors_size: 0,
            image: [],
            image_size: 0,
            points_frame_id: CoordinateFrameId.FLU.rawValue,
            image_frame_id: CoordinateFrameId.RDF.rawValue
        )
        latestCameraFrame = nil
        isDataDirty = false
    }

    private func resetStreamWorkerState() {
        streamStateQueue.sync {
            streamWorkerState.generation &+= 1
            streamWorkerState.pendingRequest = nil
            streamWorkerState.isRunning = false
        }
    }

    private func profileNow() -> CFTimeInterval {
        CACurrentMediaTime()
    }

    private func recordReceivedFrame(overwrotePending: Bool) {
        guard enableAVProfiling else { return }
        let now = profileNow()
        profileLock.lock()
        if profileWindow.windowStartTime == 0 {
            profileWindow.windowStartTime = now
        }
        profileWindow.receivedFrames += 1
        if overwrotePending {
            profileWindow.overwrittenFrames += 1
        }
        profileLock.unlock()
    }

    private func recordThrottledFrame(context: AVProfileContext) {
        guard enableAVProfiling else { return }
        let now = profileNow()
        profileLock.lock()
        if profileWindow.windowStartTime == 0 {
            profileWindow.windowStartTime = now
        }
        profileWindow.throttledFrames += 1
        let summary = makeProfileSummaryIfNeededLocked(now: now, context: context)
        profileLock.unlock()
        if let summary {
            print(summary)
        }
    }

    private func recordProcessedFrame(
        totalSeconds: Double,
        rgbConversionSeconds: Double,
        rgbProfile: RGBProfilingSample,
        wasmPointCloudSeconds: Double,
        webSocketPointCloudSeconds: Double,
        previewSeconds: Double,
        jpegStreamSeconds: Double,
        stateUpdateSeconds: Double,
        inferenceSubmitSeconds: Double,
        builtMonitoredImage: Bool,
        bypassedStreamImage: Bool,
        context: AVProfileContext
    ) {
        guard enableAVProfiling else { return }
        let now = profileNow()
        profileLock.lock()
        if profileWindow.windowStartTime == 0 {
            profileWindow.windowStartTime = now
        }
        profileWindow.processedFrames += 1
        profileWindow.totalProcess.record(totalSeconds)
        profileWindow.rgbConversion.record(rgbConversionSeconds)
        profileWindow.rgbFormatDetect.record(rgbProfile.formatDetectSeconds)
        profileWindow.rgbPixelBufferLock.record(rgbProfile.pixelBufferLockSeconds)
        profileWindow.rgbYCbCrConvert.record(rgbProfile.yCbCrConvertSeconds)
        profileWindow.rgbScaleRotate.record(rgbProfile.scaleRotateSeconds)
        profileWindow.rgbPack.record(rgbProfile.packSeconds)
        profileWindow.rgbUIImage.record(rgbProfile.uiImageSeconds)
        profileWindow.wasmPointCloud.record(wasmPointCloudSeconds)
        profileWindow.webSocketPointCloud.record(webSocketPointCloudSeconds)
        profileWindow.preview.record(previewSeconds)
        profileWindow.jpegStream.record(jpegStreamSeconds)
        profileWindow.stateUpdate.record(stateUpdateSeconds)
        profileWindow.inferenceSubmit.record(inferenceSubmitSeconds)
        if rgbProfile.usedFallback {
            profileWindow.rgbFallbackFrames += 1
        }
        if builtMonitoredImage {
            profileWindow.monitoredImageFrames += 1
        }
        if bypassedStreamImage {
            profileWindow.streamBypassedFrames += 1
        }
        let summary = makeProfileSummaryIfNeededLocked(now: now, context: context)
        profileLock.unlock()
        if let summary {
            print(summary)
        }
    }

    private func makeProfileSummaryIfNeededLocked(
        now: CFTimeInterval,
        context: AVProfileContext
    ) -> String? {
        guard profileWindow.windowStartTime > 0 else { return nil }
        let elapsed = now - profileWindow.windowStartTime
        guard elapsed >= profilingSummaryInterval else { return nil }

        let fps = elapsed > 0 ? Double(profileWindow.processedFrames) / elapsed : 0
        let summary = String(
            format: "[av][profile] window=%.1fs recv=%d proc=%d overwrite=%d throttle=%d monitored_img=%d bypassed_stream=%d rgb_fb=%d fps=%.1f total=%.1f/%.1fms rgb=%.1f/%.1fms rgb_fmt=%.3f rgb_lock=%.3f rgb_conv=%.1f rgb_sr=%.1f rgb_pack=%.1f rgb_ui=%.1f wasm_pc=%.1f/%.1fms ws_pc=%.1f/%.1fms preview=%.1f/%.1fms jpeg=%.1f/%.1fms state=%.1f/%.1fms submit=%.3f/%.3fms clients=%d stream=%d preview=%@ models=%d",
            elapsed,
            profileWindow.receivedFrames,
            profileWindow.processedFrames,
            profileWindow.overwrittenFrames,
            profileWindow.throttledFrames,
            profileWindow.monitoredImageFrames,
            profileWindow.streamBypassedFrames,
            profileWindow.rgbFallbackFrames,
            fps,
            profileWindow.totalProcess.averageMilliseconds,
            profileWindow.totalProcess.maxMilliseconds,
            profileWindow.rgbConversion.averageMilliseconds,
            profileWindow.rgbConversion.maxMilliseconds,
            profileWindow.rgbFormatDetect.averageMilliseconds,
            profileWindow.rgbPixelBufferLock.averageMilliseconds,
            profileWindow.rgbYCbCrConvert.averageMilliseconds,
            profileWindow.rgbScaleRotate.averageMilliseconds,
            profileWindow.rgbPack.averageMilliseconds,
            profileWindow.rgbUIImage.averageMilliseconds,
            profileWindow.wasmPointCloud.averageMilliseconds,
            profileWindow.wasmPointCloud.maxMilliseconds,
            profileWindow.webSocketPointCloud.averageMilliseconds,
            profileWindow.webSocketPointCloud.maxMilliseconds,
            profileWindow.preview.averageMilliseconds,
            profileWindow.preview.maxMilliseconds,
            profileWindow.jpegStream.averageMilliseconds,
            profileWindow.jpegStream.maxMilliseconds,
            profileWindow.stateUpdate.averageMilliseconds,
            profileWindow.stateUpdate.maxMilliseconds,
            profileWindow.inferenceSubmit.averageMilliseconds,
            profileWindow.inferenceSubmit.maxMilliseconds,
            context.hasWebSocketClients ? 1 : 0,
            context.isStreaming ? 1 : 0,
            String(describing: context.previewMode),
            context.hasActiveModels ? 1 : 0
        )
        profileWindow.reset(startTime: now)
        return summary
    }

    func latestCameraFrameSnapshot() -> CameraImageFrame? {
        lock.lock()
        let frame = latestCameraFrame
        lock.unlock()
        return frame
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

    private func submitStreamFrame(frame: CameraImageFrame) {
        let request = StreamFrameRequest(frame: frame)
        streamStateQueue.async {
            self.streamWorkerState.pendingRequest = request
            guard !self.streamWorkerState.isRunning else {
                return
            }

            self.streamWorkerState.isRunning = true
            let generation = self.streamWorkerState.generation
            self.startNextStreamWork(generation: generation)
        }
    }

    private func startNextStreamWork(generation: UInt64) {
        streamStateQueue.async {
            guard self.streamWorkerState.generation == generation else {
                return
            }

            guard let request = self.streamWorkerState.pendingRequest else {
                self.streamWorkerState.isRunning = false
                return
            }
            self.streamWorkerState.pendingRequest = nil

            self.streamExecutionQueue.async {
                _ = self.streamFrame(frame: request.frame)
                self.startNextStreamWork(generation: generation)
            }
        }
    }

    // MARK: - Session Control

    func start() {
        lock.lock()
        resetWasmFrameStateLocked()
        lock.unlock()
        resetStreamWorkerState()

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
            self.resetWasmFrameStateLocked()
            self.lock.unlock()
            self.resetStreamWorkerState()

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

    private func streamFrame(image: UIImage) -> Bool {
        guard isStreaming else { return false }

        let currentTime = CACurrentMediaTime()
        let frameInterval = 1.0 / Double(streamTargetFPS)

        // Throttle frame rate.
        if currentTime - lastStreamTime < frameInterval {
            return false
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
            return true
        }
        return false
    }

    private func streamFrame(frame: CameraImageFrame) -> Bool {
        guard isStreaming else { return false }

        let currentTime = CACurrentMediaTime()
        let frameInterval = 1.0 / Double(streamTargetFPS)
        if currentTime - lastStreamTime < frameInterval {
            return false
        }

        guard let jpegData = jpegData(for: frame) else {
            return false
        }

        lastStreamTime = currentTime
        streamFrameCount += 1
        if currentTime - lastFPSUpdateTime >= 1.0 {
            DispatchQueue.main.async {
                self.streamFPS = Double(self.streamFrameCount)
            }
            streamFrameCount = 0
            lastFPSUpdateTime = currentTime
        }

        WebSocketManager.shared.broadcastBinaryData(jpegData)
        return true
    }

    private func jpegData(for frame: CameraImageFrame) -> Data? {
        guard frame.width > 0, frame.height > 0, frame.channels == 3 else {
            return nil
        }

        var rgbaBytes = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        var srcIndex = 0
        var dstIndex = 0
        while srcIndex + 2 < frame.rgbBytes.count, dstIndex + 3 < rgbaBytes.count {
            rgbaBytes[dstIndex] = frame.rgbBytes[srcIndex]
            rgbaBytes[dstIndex + 1] = frame.rgbBytes[srcIndex + 1]
            rgbaBytes[dstIndex + 2] = frame.rgbBytes[srcIndex + 2]
            rgbaBytes[dstIndex + 3] = 255
            srcIndex += 3
            dstIndex += 4
        }

        guard let context = CGContext(
            data: &rgbaBytes,
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bytesPerRow: frame.width * 4,
            space: renderColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
            .jpegData(compressionQuality: streamJpegQuality)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock()
        let overwrotePendingFrame = isProcessingFrame && currentFrame != nil
        currentFrame = frame
        hasNewFrame = true
        let shouldStartProcessing = !isProcessingFrame
        if shouldStartProcessing {
            isProcessingFrame = true
        }
        lock.unlock()
        recordReceivedFrame(overwrotePending: overwrotePendingFrame)

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
        let processStartedAt = profileNow()
        let processInterval = 1.0 / processingTargetFPS
        if lastProcessedFrameTimestamp > 0,
           frame.timestamp - lastProcessedFrameTimestamp < processInterval {
            let context = AVProfileContext(
                hasWebSocketClients: WebSocketManager.shared.hasConnectedWebSocketClients(),
                isStreaming: isStreaming,
                previewMode: previewMode,
                hasActiveModels: ModelRunner.shared.hasActiveModels()
            )
            recordThrottledFrame(context: context)
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
        let hasWebSocketClients = WebSocketManager.shared.hasConnectedWebSocketClients()
        let hasActiveModels = ModelRunner.shared.hasActiveModels()
        let profileContext = AVProfileContext(
            hasWebSocketClients: hasWebSocketClients,
            isStreaming: isStreaming,
            previewMode: localPreviewMode,
            hasActiveModels: hasActiveModels
        )

        let shouldPublishWebSocketPointCloud: Bool
        if hasWebSocketClients {
            if lastWebSocketPointCloudTimestamp == 0 {
                shouldPublishWebSocketPointCloud = true
                lastWebSocketPointCloudTimestamp = frame.timestamp
            } else if frame.timestamp - lastWebSocketPointCloudTimestamp >= (1.0 / websocketPointCloudTargetFPS) {
                shouldPublishWebSocketPointCloud = true
                lastWebSocketPointCloudTimestamp = frame.timestamp
            } else {
                shouldPublishWebSocketPointCloud = false
            }
        } else {
            shouldPublishWebSocketPointCloud = false
        }
        let needsPointColors = includePointColorsForWasm
        let needsImagePayload = includeImageInWasmPayload
        let needsModelImage = hasActiveModels
        let needsMonitoredStreamImage = isStreaming && hasWebSocketClients
        let needsUIImage = needsPreviewVideo
        let needsCanonicalRGBFrame = needsImagePayload || needsModelImage || needsMonitoredStreamImage
        let needsRGBFrame = needsCanonicalRGBFrame || needsUIImage

        let imageResolution = frame.camera.imageResolution
        let fallbackLayout = portraitLayout(
            width: Int(imageResolution.width),
            height: Int(imageResolution.height)
        )

        let rgbFrame: RGBFrameData?
        let rgbProfile: RGBProfilingSample
        let rgbStartedAt = profileNow()
        if needsRGBFrame {
            let rgbResult = rgbFrameData(
                from: frame.capturedImage,
                downsampleFactor: rgbDownsampleFactor,
                includeUIImage: needsUIImage,
                includePortraitBytes: needsCanonicalRGBFrame
            )
            rgbFrame = rgbResult.frame
            rgbProfile = rgbResult.profile
        } else {
            rgbFrame = nil
            rgbProfile = RGBProfilingSample()
        }
        let rgbDuration = profileNow() - rgbStartedAt

        let wasmPointCloudStartedAt = profileNow()
        let pointCloudData = depthDataToPointCloud(
            depthMap: depthData.depthMap,
            confidenceMap: depthData.confidenceMap,
            frame: frame,
            colorSource: nil,
            colorPixelBuffer: needsPointColors ? frame.capturedImage : nil
        )
        let wasmPointCloudDuration = profileNow() - wasmPointCloudStartedAt

        let webSocketPointCloudData: PointCloudExportData?
        let webSocketPointCloudStartedAt = profileNow()
        if shouldPublishWebSocketPointCloud {
            webSocketPointCloudData = depthDataToPointCloud(
                depthMap: depthData.depthMap,
                confidenceMap: depthData.confidenceMap,
                frame: frame,
                colorSource: nil,
                colorPixelBuffer: frame.capturedImage,
                pointStride: websocketPointCloudStride,
                maxPointCount: websocketPointCloudMaxPoints
            )
        } else {
            webSocketPointCloudData = nil
        }
        let webSocketPointCloudDuration = profileNow() - webSocketPointCloudStartedAt

        let canonicalCameraFrame: CameraImageFrame? = {
            guard needsCanonicalRGBFrame,
                  let rgbFrame,
                  !rgbFrame.portraitBytes.isEmpty else {
                return nil
            }
            return CameraImageFrame(
                timestamp: frame.timestamp,
                width: rgbFrame.portraitWidth,
                height: rgbFrame.portraitHeight,
                channels: 3,
                rgbBytes: rgbFrame.portraitBytes
            )
        }()

        let jpegStreamStartedAt = profileNow()
        if needsMonitoredStreamImage, let canonicalCameraFrame {
            submitStreamFrame(frame: canonicalCameraFrame)
        }
        let jpegStreamDuration = profileNow() - jpegStreamStartedAt

        let previewStartedAt = profileNow()
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
        let previewDuration = profileNow() - previewStartedAt

        let stateUpdateStartedAt = profileNow()
        lock.lock()
        currentImageWidth = Int32(rgbFrame?.portraitWidth ?? fallbackLayout.width)
        currentImageHeight = Int32(rgbFrame?.portraitHeight ?? fallbackLayout.height)
        currentImageChannels = 3

        let imageBytes = needsImagePayload ? (rgbFrame?.portraitBytes ?? []) : []
        latestCameraFrame = needsModelImage ? canonicalCameraFrame : nil
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
        let stateUpdateDuration = profileNow() - stateUpdateStartedAt

        let inferenceSubmitStartedAt = profileNow()
        let shouldSubmitInference: Bool
        if hasActiveModels, hasWebSocketClients, canonicalCameraFrame != nil {
            if lastInferenceSubmissionTimestamp == 0 ||
                frame.timestamp - lastInferenceSubmissionTimestamp >= (1.0 / inferenceTargetFPS) {
                shouldSubmitInference = true
                lastInferenceSubmissionTimestamp = frame.timestamp
            } else {
                shouldSubmitInference = false
            }
        } else {
            shouldSubmitInference = false
        }

        if shouldSubmitInference, let canonicalCameraFrame {
            ModelRunner.shared.submitActiveModels(frame: canonicalCameraFrame) { frame, modelResults, _ in
                WebSocketManager.shared.publishMlDetections(
                    frame: frame,
                    modelResults: modelResults
                )
            }
        }
        let inferenceSubmitDuration = profileNow() - inferenceSubmitStartedAt

        if let webSocketPointCloudData,
           webSocketPointCloudData.pointCount > 0 {
            webSocketPointCloudData.points.withUnsafeBufferPointer { pointsBuffer in
                guard let pointsPointer = pointsBuffer.baseAddress else { return }
                webSocketPointCloudData.colors.withUnsafeBufferPointer { colorsBuffer in
                    WebSocketManager.shared.broadcastPointCloud(
                        timestamp: frame.timestamp,
                        pointsPointer: pointsPointer,
                        pointCount: webSocketPointCloudData.pointCount,
                        colorsPointer: colorsBuffer.baseAddress,
                        colorsCount: webSocketPointCloudData.colors.count
                    )
                }
            }
        }

        recordProcessedFrame(
            totalSeconds: profileNow() - processStartedAt,
            rgbConversionSeconds: rgbDuration,
            rgbProfile: rgbProfile,
            wasmPointCloudSeconds: wasmPointCloudDuration,
            webSocketPointCloudSeconds: webSocketPointCloudDuration,
            previewSeconds: previewDuration,
            jpegStreamSeconds: jpegStreamDuration,
            stateUpdateSeconds: stateUpdateDuration,
            inferenceSubmitSeconds: inferenceSubmitDuration,
            builtMonitoredImage: needsMonitoredStreamImage,
            bypassedStreamImage: isStreaming && !hasWebSocketClients,
            context: profileContext
        )
    }

    // MARK: - Camera / Image Conversion

    private func rgbFrameData(
        from pixelBuffer: CVPixelBuffer,
        downsampleFactor: Int,
        includeUIImage: Bool,
        includePortraitBytes: Bool
    ) -> (frame: RGBFrameData?, profile: RGBProfilingSample) {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let factor = max(1, downsampleFactor)
        let width = max(1, sourceWidth / factor)
        let height = max(1, sourceHeight / factor)
        let layout = portraitLayout(width: width, height: height)

        var profile = RGBProfilingSample()
        let formatDetectStartedAt = profileNow()
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        profile.formatDetectSeconds = profileNow() - formatDetectStartedAt

        let lowerLevelFormats: Set<OSType> = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        if lowerLevelFormats.contains(pixelFormat), planeCount >= 2 {
            if let frame = rgbFrameDataFromBiPlanarPixelBuffer(
                pixelBuffer,
                pixelFormat: pixelFormat,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                scaledWidth: width,
                scaledHeight: height,
                layout: layout,
                includeUIImage: includeUIImage,
                includePortraitBytes: includePortraitBytes,
                profile: &profile
            ) {
                return (frame, profile)
            }
            profile.usedFallback = true
        } else {
            profile.usedFallback = true
        }

        let fallbackFrame = rgbFrameDataUsingCoreImage(
            from: pixelBuffer,
            scaledWidth: width,
            scaledHeight: height,
            layout: layout,
            includeUIImage: includeUIImage,
            includePortraitBytes: includePortraitBytes,
            profile: &profile
        )
        return (fallbackFrame, profile)
    }

    private func ensureByteBuffer(_ buffer: inout [UInt8], count: Int) {
        guard buffer.count != count else { return }
        buffer = [UInt8](repeating: 0, count: count)
    }

    private func clampToByte(_ value: Int) -> UInt8 {
        if value < 0 {
            return 0
        }
        if value > 255 {
            return 255
        }
        return UInt8(value)
    }

    private func yCbCrMatrixForPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> UnsafePointer<vImage_YpCbCrToARGBMatrix> {
        guard let attachment = CVBufferGetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            nil
        )?.takeUnretainedValue() else {
            return kvImage_YpCbCrToARGBMatrix_ITU_R_709_2
        }

        if CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            return kvImage_YpCbCrToARGBMatrix_ITU_R_601_4
        }
        return kvImage_YpCbCrToARGBMatrix_ITU_R_709_2
    }

    private func pixelRangeForFormat(_ pixelFormat: OSType) -> vImage_YpCbCrPixelRange {
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            return vImage_YpCbCrPixelRange(
                Yp_bias: 16,
                CbCr_bias: 128,
                YpRangeMax: 235,
                CbCrRangeMax: 240,
                YpMax: 255,
                YpMin: 0,
                CbCrMax: 255,
                CbCrMin: 1
            )
        }

        return vImage_YpCbCrPixelRange(
            Yp_bias: 0,
            CbCr_bias: 128,
            YpRangeMax: 255,
            CbCrRangeMax: 255,
            YpMax: 255,
            YpMin: 1,
            CbCrMax: 255,
            CbCrMin: 0
        )
    }

    private func withYpCbCrConversionInfo<T>(
        for pixelBuffer: CVPixelBuffer,
        pixelFormat: OSType,
        body: (UnsafePointer<vImage_YpCbCrToARGB>) -> T?
    ) -> T? {
        let matrix = yCbCrMatrixForPixelBuffer(pixelBuffer)
        var pixelRange = pixelRangeForFormat(pixelFormat)

        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            if !hasVideoRangeYpCbCrToARGB {
                let error = vImageConvert_YpCbCrToARGB_GenerateConversion(
                    matrix,
                    &pixelRange,
                    &videoRangeYpCbCrToARGB,
                    kvImage420Yp8_CbCr8,
                    kvImageARGB8888,
                    vImage_Flags(kvImageNoFlags)
                )
                guard error == kvImageNoError else {
                    return nil
                }
                hasVideoRangeYpCbCrToARGB = true
            }
            return withUnsafePointer(to: &videoRangeYpCbCrToARGB, body)
        }

        if !hasFullRangeYpCbCrToARGB {
            let error = vImageConvert_YpCbCrToARGB_GenerateConversion(
                matrix,
                &pixelRange,
                &fullRangeYpCbCrToARGB,
                kvImage420Yp8_CbCr8,
                kvImageARGB8888,
                vImage_Flags(kvImageNoFlags)
            )
            guard error == kvImageNoError else {
                return nil
            }
            hasFullRangeYpCbCrToARGB = true
        }
        return withUnsafePointer(to: &fullRangeYpCbCrToARGB, body)
    }

    private func makeUIImageFromRGBBytes(
        _ rgbBytes: [UInt8],
        width: Int,
        height: Int
    ) -> UIImage? {
        guard width > 0, height > 0, rgbBytes.count == width * height * 3 else {
            return nil
        }

        var rgbaBytes = [UInt8](repeating: 0, count: width * height * 4)
        var srcIndex = 0
        var dstIndex = 0
        while srcIndex + 2 < rgbBytes.count, dstIndex + 3 < rgbaBytes.count {
            rgbaBytes[dstIndex] = rgbBytes[srcIndex]
            rgbaBytes[dstIndex + 1] = rgbBytes[srcIndex + 1]
            rgbaBytes[dstIndex + 2] = rgbBytes[srcIndex + 2]
            rgbaBytes[dstIndex + 3] = 255
            srcIndex += 3
            dstIndex += 4
        }

        guard let context = CGContext(
            data: &rgbaBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: renderColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private func packedRGBBytesFromARGB(
        _ argbBytes: [UInt8],
        width: Int,
        height: Int,
        reuseBuffer: inout [UInt8]
    ) -> [UInt8]? {
        guard width > 0,
              height > 0,
              argbBytes.count == width * height * 4 else {
            return nil
        }

        ensureByteBuffer(&reuseBuffer, count: width * height * 3)
        var sourceBytes = argbBytes
        let conversionError = sourceBytes.withUnsafeMutableBytes { srcRawBuffer -> vImage_Error in
            reuseBuffer.withUnsafeMutableBytes { dstRawBuffer -> vImage_Error in
                guard let srcBaseAddress = srcRawBuffer.baseAddress,
                      let dstBaseAddress = dstRawBuffer.baseAddress else {
                    return kvImageNullPointerArgument
                }

                var srcBuffer = vImage_Buffer(
                    data: srcBaseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                var dstBuffer = vImage_Buffer(
                    data: dstBaseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 3
                )
                return vImageConvert_ARGB8888toRGB888(
                    &srcBuffer,
                    &dstBuffer,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }

        guard conversionError == kvImageNoError else {
            return nil
        }
        return reuseBuffer
    }

    private func rgbFrameDataFromBiPlanarPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        pixelFormat: OSType,
        sourceWidth: Int,
        sourceHeight: Int,
        scaledWidth: Int,
        scaledHeight: Int,
        layout: (width: Int, height: Int, rotate: Bool),
        includeUIImage: Bool,
        includePortraitBytes: Bool,
        profile: inout RGBProfilingSample
    ) -> RGBFrameData? {
        let lockStartedAt = profileNow()
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let lockAcquiredAt = profileNow()
        profile.pixelBufferLockSeconds += lockAcquiredAt - lockStartedAt

        guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            profile.pixelBufferLockSeconds += profileNow() - lockAcquiredAt
            return nil
        }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let targetWidth = layout.width
        let targetHeight = layout.height

        ensureByteBuffer(&fullResolutionARGBBytes, count: sourceWidth * sourceHeight * 4)
        if layout.rotate {
            ensureByteBuffer(&scaledARGBBytes, count: scaledWidth * scaledHeight * 4)
        } else {
            scaledARGBBytes.removeAll(keepingCapacity: true)
        }
        ensureByteBuffer(&renderARGBBytes, count: targetWidth * targetHeight * 4)

        let convertStartedAt = profileNow()
        var yBuffer = vImage_Buffer(
            data: yBaseAddress,
            height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth),
            rowBytes: yBytesPerRow
        )
        var cbCrBuffer = vImage_Buffer(
            data: uvBaseAddress,
            height: vImagePixelCount(sourceHeight / 2),
            width: vImagePixelCount(sourceWidth / 2),
            rowBytes: uvBytesPerRow
        )
        var fullBuffer = vImage_Buffer(
            data: &fullResolutionARGBBytes,
            height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth),
            rowBytes: sourceWidth * 4
        )
        let permuteMap: [UInt8] = [0, 1, 2, 3]
        let convertSucceeded = withYpCbCrConversionInfo(for: pixelBuffer, pixelFormat: pixelFormat) { conversionInfo in
            vImageConvert_420Yp8_CbCr8ToARGB8888(
                &yBuffer,
                &cbCrBuffer,
                &fullBuffer,
                conversionInfo,
                permuteMap,
                255,
                vImage_Flags(kvImageNoFlags)
            ) == kvImageNoError
        } ?? false
        guard convertSucceeded else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            profile.pixelBufferLockSeconds += profileNow() - lockAcquiredAt
            return nil
        }
        profile.yCbCrConvertSeconds = profileNow() - convertStartedAt

        let scaleRotateStartedAt = profileNow()
        let scaleFlags = vImage_Flags(kvImageHighQualityResampling)
        let scaleError: vImage_Error
        if layout.rotate {
            var scaledBuffer = vImage_Buffer(
                data: &scaledARGBBytes,
                height: vImagePixelCount(scaledHeight),
                width: vImagePixelCount(scaledWidth),
                rowBytes: scaledWidth * 4
            )
            scaleError = vImageScale_ARGB8888(&fullBuffer, &scaledBuffer, nil, scaleFlags)
            guard scaleError == kvImageNoError else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                profile.pixelBufferLockSeconds += profileNow() - lockAcquiredAt
                return nil
            }

            var renderBuffer = vImage_Buffer(
                data: &renderARGBBytes,
                height: vImagePixelCount(targetHeight),
                width: vImagePixelCount(targetWidth),
                rowBytes: targetWidth * 4
            )
            var backgroundColor: [UInt8] = [255, 0, 0, 0]
            let rotateError = vImageRotate90_ARGB8888(
                &scaledBuffer,
                &renderBuffer,
                UInt8(kRotate90DegreesClockwise),
                &backgroundColor,
                vImage_Flags(kvImageNoFlags)
            )
            guard rotateError == kvImageNoError else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                profile.pixelBufferLockSeconds += profileNow() - lockAcquiredAt
                return nil
            }
        } else {
            var renderBuffer = vImage_Buffer(
                data: &renderARGBBytes,
                height: vImagePixelCount(targetHeight),
                width: vImagePixelCount(targetWidth),
                rowBytes: targetWidth * 4
            )
            scaleError = vImageScale_ARGB8888(&fullBuffer, &renderBuffer, nil, scaleFlags)
            guard scaleError == kvImageNoError else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                profile.pixelBufferLockSeconds += profileNow() - lockAcquiredAt
                return nil
            }
        }
        profile.scaleRotateSeconds = profileNow() - scaleRotateStartedAt

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        profile.pixelBufferLockSeconds += profileNow() - lockAcquiredAt

        let packStartedAt = profileNow()
        let portraitBytes: [UInt8]
        if includePortraitBytes {
            guard let rgbBytes = packedRGBBytesFromARGB(
                renderARGBBytes,
                width: targetWidth,
                height: targetHeight,
                reuseBuffer: &packedRGBBytes
            ) else {
                return nil
            }
            portraitBytes = rgbBytes
        } else {
            portraitBytes = []
        }
        profile.packSeconds = profileNow() - packStartedAt

        let uiImage: UIImage?
        if includeUIImage {
            let uiStartedAt = profileNow()
            let previewRGBBytes: [UInt8]
            if includePortraitBytes {
                previewRGBBytes = portraitBytes
            } else {
                guard let rgbBytes = packedRGBBytesFromARGB(
                    renderARGBBytes,
                    width: targetWidth,
                    height: targetHeight,
                    reuseBuffer: &packedRGBBytes
                ) else {
                    return nil
                }
                previewRGBBytes = rgbBytes
            }
            uiImage = makeUIImageFromRGBBytes(previewRGBBytes, width: targetWidth, height: targetHeight)
            profile.uiImageSeconds = profileNow() - uiStartedAt
        } else {
            uiImage = nil
        }

        return RGBFrameData(
            rawBytes: portraitBytes,
            rawWidth: targetWidth,
            rawHeight: targetHeight,
            portraitBytes: portraitBytes,
            portraitWidth: targetWidth,
            portraitHeight: targetHeight,
            uiImage: uiImage
        )
    }

    private func rgbFrameDataUsingCoreImage(
        from pixelBuffer: CVPixelBuffer,
        scaledWidth: Int,
        scaledHeight: Int,
        layout: (width: Int, height: Int, rotate: Bool),
        includeUIImage: Bool,
        includePortraitBytes: Bool,
        profile: inout RGBProfilingSample
    ) -> RGBFrameData? {
        let targetWidth = layout.width
        let targetHeight = layout.height
        let renderBounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let rgbaByteCount = targetWidth * targetHeight * 4
        ensureByteBuffer(&fallbackRGBABytes, count: rgbaByteCount)

        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if layout.rotate {
            ciImage = ciImage.oriented(.right)
        }

        let orientedExtent = ciImage.extent.integral
        let scaleX = CGFloat(targetWidth) / max(orientedExtent.width, 1)
        let scaleY = CGFloat(targetHeight) / max(orientedExtent.height, 1)
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let scaledExtent = ciImage.extent.integral
        if scaledExtent.origin != .zero {
            ciImage = ciImage.transformed(
                by: CGAffineTransform(
                    translationX: -scaledExtent.origin.x,
                    y: -scaledExtent.origin.y
                )
            )
        }

        let rowBytes = targetWidth * 4
        let rendered = fallbackRGBABytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            let renderStartedAt = profileNow()
            ciContext.render(
                ciImage,
                toBitmap: baseAddress,
                rowBytes: rowBytes,
                bounds: renderBounds,
                format: .RGBA8,
                colorSpace: renderColorSpace
            )
            profile.scaleRotateSeconds += profileNow() - renderStartedAt
            return true
        }
        guard rendered else { return nil }

        let portraitBytes: [UInt8]
        if includePortraitBytes {
            let packStartedAt = profileNow()
            var rgbBytes = [UInt8](repeating: 0, count: targetWidth * targetHeight * 3)
            var srcIndex = 0
            var dstIndex = 0
            while srcIndex + 3 < fallbackRGBABytes.count {
                rgbBytes[dstIndex] = fallbackRGBABytes[srcIndex]
                rgbBytes[dstIndex + 1] = fallbackRGBABytes[srcIndex + 1]
                rgbBytes[dstIndex + 2] = fallbackRGBABytes[srcIndex + 2]
                srcIndex += 4
                dstIndex += 3
            }
            portraitBytes = rgbBytes
            profile.packSeconds += profileNow() - packStartedAt
        } else {
            portraitBytes = []
        }

        let uiImage: UIImage?
        if includeUIImage {
            let uiStartedAt = profileNow()
            let previewRGBBytes: [UInt8]
            if includePortraitBytes {
                previewRGBBytes = portraitBytes
            } else {
                var rgbBytes = [UInt8](repeating: 0, count: targetWidth * targetHeight * 3)
                var srcIndex = 0
                var dstIndex = 0
                while srcIndex + 3 < fallbackRGBABytes.count {
                    rgbBytes[dstIndex] = fallbackRGBABytes[srcIndex]
                    rgbBytes[dstIndex + 1] = fallbackRGBABytes[srcIndex + 1]
                    rgbBytes[dstIndex + 2] = fallbackRGBABytes[srcIndex + 2]
                    srcIndex += 4
                    dstIndex += 3
                }
                previewRGBBytes = rgbBytes
            }
            uiImage = makeUIImageFromRGBBytes(previewRGBBytes, width: targetWidth, height: targetHeight)
            profile.uiImageSeconds += profileNow() - uiStartedAt
        } else {
            uiImage = nil
        }

        return RGBFrameData(
            rawBytes: portraitBytes,
            rawWidth: targetWidth,
            rawHeight: targetHeight,
            portraitBytes: portraitBytes,
            portraitWidth: targetWidth,
            portraitHeight: targetHeight,
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
        colorPixelBuffer: CVPixelBuffer?,
        pointStride: Int? = nil,
        maxPointCount: Int? = nil
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

        let pointStride = max(1, pointStride ?? LidarCameraConstants.pointSubsampleStride)
        let maxPointCount = max(1, min(maxPointCount ?? LidarCameraConstants.maxPointsPerScan, LidarCameraConstants.maxPointsPerScan))
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
        let wantsColors = hasRgbColorSource || hasYuvColorSource
        var colors = wantsColors
            ? [UInt8](
                repeating: 0,
                count: estimatedPoints * LidarCameraConstants.colorsPerPoint
            )
            : []

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

    let pointsFrameIdOffset = imageSizeOffset + MemoryLayout<Int32>.size
    let imageFrameIdOffset = pointsFrameIdOffset + MemoryLayout<Int32>.size
    let totalBytes = imageFrameIdOffset + MemoryLayout<Int32>.size

    if let nativeEnd = nativeEnd {
        let baseAddr = UInt(bitPattern: basePtr)
        let endAddr = UInt(bitPattern: nativeEnd)
        if baseAddr + UInt(totalBytes) > endAddr {
            return
        }
    }

    func clearFrame() {
        basePtr.withMemoryRebound(to: Double.self, capacity: 1) { rebounded in
            rebounded.pointee = 0.0
        }
        basePtr.advanced(by: pointsSizeOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
            rebounded.pointee = 0
        }
        basePtr.advanced(by: colorsSizeOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
            rebounded.pointee = 0
        }
        basePtr.advanced(by: imageSizeOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
            rebounded.pointee = 0
        }
        basePtr.advanced(by: pointsFrameIdOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
            rebounded.pointee = CoordinateFrameId.FLU.rawValue
        }
        basePtr.advanced(by: imageFrameIdOffset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
            rebounded.pointee = CoordinateFrameId.RDF.rawValue
        }
    }

    manager.lock.lock()
    guard manager.isDataDirty else {
        manager.lock.unlock()
        clearFrame()
        return
    }
    let data = manager.currentData
    manager.isDataDirty = false
    manager.lock.unlock()

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
