import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

private enum WasmLidarLayout {
    static let pointsOffset = MemoryLayout<Double>.size
    static let pointsMaxCount = LidarCameraConstants.maxPointsSize
    static let pointsByteCount = pointsMaxCount * MemoryLayout<Float32>.size
    static let pointsSizeOffset = pointsOffset + pointsByteCount
    static let pointsSizeBytes = MemoryLayout<Int32>.size

    static let colorsOffset = pointsSizeOffset + pointsSizeBytes
    static let colorsMaxCount = LidarCameraConstants.maxColorsSize
    static let colorsByteCount = colorsMaxCount * MemoryLayout<UInt8>.size
    static let colorsSizeOffset = colorsOffset + colorsByteCount
    static let colorsSizeBytes = MemoryLayout<Int32>.size

    static let imageOffset = colorsSizeOffset + colorsSizeBytes
    static let imageMaxCount = LidarCameraConstants.maxImageSize
    static let imageByteCount = imageMaxCount * MemoryLayout<UInt8>.size
    static let imageSizeOffset = imageOffset + imageByteCount
    static let imageSizeBytes = MemoryLayout<Int32>.size

    static let totalByteCount = imageSizeOffset + imageSizeBytes
}

private struct WasmLidarFrameView {
    let timestamp: Double
    let pointsPointer: UnsafeMutablePointer<Float32>
    let pointsCount: Int
    let colorsPointer: UnsafeMutablePointer<UInt8>
    let colorsCount: Int
    let imagePointer: UnsafeMutablePointer<UInt8>
    let imageCount: Int
}

private final class RGBJpegEncoder {
    private let quality: CGFloat

    init(quality: CGFloat) {
        self.quality = quality
    }

    func encode(
        rgbPointer: UnsafeMutablePointer<UInt8>,
        byteCount: Int,
        width: Int,
        height: Int
    ) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let expectedCount = width * height * 3
        guard byteCount >= expectedCount else { return nil }

        let rgbRawPointer = UnsafeMutableRawPointer(rgbPointer)
        let rgbData = Data(bytesNoCopy: rgbRawPointer, count: expectedCount, deallocator: .none)
        guard let provider = CGDataProvider(data: rgbData as CFData) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return outputData as Data
    }
}

private final class WasmRerunTelemetryBridge {
    static let shared = WasmRerunTelemetryBridge()

    private let maxPointsToSend = 15_000
    private let videoMinInterval = 1.0 / 20.0
    private let processingLock = NSLock()
    private let stateLock = NSLock()
    private let jpegEncoder = RGBJpegEncoder(quality: 0.55)

    private var lastVideoSentTimestamp: Double = 0.0
    private var warnedImageSizeZero = false
    private var sampledPoints: [Float] = []
    private var sampledColors: [UInt8] = []

    private init() {}

    func handleWasmFrame(execEnv: wasm_exec_env_t?, payloadPointer: UnsafeMutableRawPointer?) {
        processingLock.lock()
        defer { processingLock.unlock() }

        guard let frame = decodeFrame(execEnv: execEnv, payloadPointer: payloadPointer, minPoints: 3) else {
            return
        }
        logPointCloud(frame)
        logPose(timestamp: frame.timestamp)
        logCameraImage(frame)
    }

    func handleWasmCameraKeypoints(
        execEnv: wasm_exec_env_t?,
        payloadPointer: UnsafeMutableRawPointer?,
        keypointsPointer: UnsafeMutableRawPointer?
    ) {
        processingLock.lock()
        defer { processingLock.unlock() }

        guard let frame = decodeFrame(execEnv: execEnv, payloadPointer: payloadPointer, minPoints: 0) else {
            return
        }

        // Avoid duplicate image logs when the lidar frame logger already handles it.
        if frame.pointsCount == 0 {
            logCameraImage(frame)
        }

        guard let keypoints = decodeKeypoints(execEnv: execEnv, keypointsPointer: keypointsPointer),
              !keypoints.isEmpty else {
            return
        }
        let previewCount = min(4, keypoints.count)
        let preview = keypoints.prefix(previewCount)
        print("rerun_log_camera_keypoints_impl: decoded \(keypoints.count / 2) keypoints, preview=\(Array(preview))")
        RerunWebSocketClient.shared.logCameraKeypoints(
            timestamp: frame.timestamp,
            keypoints: keypoints
        )
    }

    private func decodeFrame(
        execEnv: wasm_exec_env_t?,
        payloadPointer: UnsafeMutableRawPointer?,
        minPoints: Int
    ) -> WasmLidarFrameView? {
        guard let execEnv = execEnv, let payloadPointer = payloadPointer else { return nil }

        let basePointer = payloadPointer.assumingMemoryBound(to: UInt8.self)
        guard let moduleInstance = wasm_runtime_get_module_inst(execEnv) else {
            return nil
        }

        var nativeStart: UnsafeMutablePointer<UInt8>?
        var nativeEnd: UnsafeMutablePointer<UInt8>?
        guard wasm_runtime_get_native_addr_range(moduleInstance, basePointer, &nativeStart, &nativeEnd) else {
            return nil
        }

        if let nativeEnd = nativeEnd {
            let baseAddress = UInt(bitPattern: basePointer)
            let endAddress = UInt(bitPattern: nativeEnd)
            if baseAddress + UInt(WasmLidarLayout.totalByteCount) > endAddress {
                return nil
            }
        }

        let timestamp = basePointer.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee }
        let pointsCount = readClampedCount(
            basePointer: basePointer,
            offset: WasmLidarLayout.pointsSizeOffset,
            maxCount: WasmLidarLayout.pointsMaxCount
        )
        if pointsCount < minPoints { return nil }

        let colorsCount = readClampedCount(
            basePointer: basePointer,
            offset: WasmLidarLayout.colorsSizeOffset,
            maxCount: WasmLidarLayout.colorsMaxCount
        )
        let imageCount = readClampedCount(
            basePointer: basePointer,
            offset: WasmLidarLayout.imageSizeOffset,
            maxCount: WasmLidarLayout.imageMaxCount
        )

        if let nativeEnd = nativeEnd {
            let baseAddress = UInt(bitPattern: basePointer)
            let endAddress = UInt(bitPattern: nativeEnd)
            let pointsEnd = baseAddress + UInt(
                WasmLidarLayout.pointsOffset + pointsCount * MemoryLayout<Float32>.size
            )
            let colorsEnd = baseAddress + UInt(
                WasmLidarLayout.colorsOffset + colorsCount * MemoryLayout<UInt8>.size
            )
            let imageEnd = baseAddress + UInt(
                WasmLidarLayout.imageOffset + imageCount * MemoryLayout<UInt8>.size
            )
            if pointsEnd > endAddress || colorsEnd > endAddress || imageEnd > endAddress {
                return nil
            }
        }

        let pointsPointer = basePointer.advanced(by: WasmLidarLayout.pointsOffset)
            .withMemoryRebound(to: Float32.self, capacity: pointsCount) { $0 }
        let colorsPointer = basePointer.advanced(by: WasmLidarLayout.colorsOffset)
        let imagePointer = basePointer.advanced(by: WasmLidarLayout.imageOffset)

        return WasmLidarFrameView(
            timestamp: timestamp,
            pointsPointer: pointsPointer,
            pointsCount: pointsCount,
            colorsPointer: colorsPointer,
            colorsCount: colorsCount,
            imagePointer: imagePointer,
            imageCount: imageCount
        )
    }

    private func readClampedCount(
        basePointer: UnsafeMutablePointer<UInt8>,
        offset: Int,
        maxCount: Int
    ) -> Int {
        let value = basePointer.advanced(by: offset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        return max(0, min(Int(value), maxCount))
    }

    private func logPointCloud(_ frame: WasmLidarFrameView) {
        let totalPoints = frame.pointsCount / 3
        guard totalPoints > 0 else { return }

        let targetPoints = min(totalPoints, maxPointsToSend)
        let stride = max(1, totalPoints / max(1, targetPoints))

        sampledPoints.removeAll(keepingCapacity: true)
        sampledPoints.reserveCapacity(targetPoints * 3)

        var pointIndex = 0
        var sampledPointCount = 0
        while pointIndex < totalPoints && sampledPointCount < targetPoints {
            let src = pointIndex * 3
            sampledPoints.append(frame.pointsPointer[src])
            sampledPoints.append(frame.pointsPointer[src + 1])
            sampledPoints.append(frame.pointsPointer[src + 2])
            pointIndex += stride
            sampledPointCount += 1
        }

        var outputColors: [UInt8]? = nil
        if frame.colorsCount > 0 {
            sampledColors.removeAll(keepingCapacity: true)
            sampledColors.reserveCapacity(sampledPointCount * 3)

            var colorPointIndex = 0
            var sampledColorCount = 0
            while colorPointIndex < totalPoints && sampledColorCount < sampledPointCount {
                let colorIndex = colorPointIndex * LidarCameraConstants.colorsPerPoint
                if colorIndex + 2 < frame.colorsCount {
                    sampledColors.append(frame.colorsPointer[colorIndex + 0])
                    sampledColors.append(frame.colorsPointer[colorIndex + 1])
                    sampledColors.append(frame.colorsPointer[colorIndex + 2])
                }
                colorPointIndex += stride
                sampledColorCount += 1
            }

            if !sampledColors.isEmpty {
                outputColors = sampledColors
            }
        }

        RerunWebSocketClient.shared.logPoints(
            timestamp: frame.timestamp,
            points: sampledPoints,
            colors: outputColors
        )
    }

    private func logPose(timestamp: Double) {
        let attitude: AttitudeData
        IMUManager.shared.lock.lock()
        attitude = IMUManager.shared.currentAttitude
        IMUManager.shared.lock.unlock()

        RerunWebSocketClient.shared.logPose(
            timestamp: timestamp,
            quaternion: [attitude.quat_x, attitude.quat_y, attitude.quat_z, attitude.quat_w]
        )
    }

    private func logCameraImage(_ frame: WasmLidarFrameView) {
        if frame.imageCount == 0 {
            warnImageSizeZeroOnce()
            return
        }
        guard shouldSendVideo(at: frame.timestamp) else { return }

        let dimensions = currentCameraDimensions()
        guard let jpegData = jpegEncoder.encode(
            rgbPointer: frame.imagePointer,
            byteCount: frame.imageCount,
            width: dimensions.width,
            height: dimensions.height
        ) else {
            return
        }

        RerunWebSocketClient.shared.logVideoFrame(
            timestamp: frame.timestamp,
            jpegData: jpegData,
            width: dimensions.width,
            height: dimensions.height
        )
    }

    private func currentCameraDimensions() -> (width: Int, height: Int) {
        AVManager.shared.lock.lock()
        let width = Int(AVManager.shared.currentImageWidth)
        let height = Int(AVManager.shared.currentImageHeight)
        AVManager.shared.lock.unlock()
        return (width, height)
    }

    private func shouldSendVideo(at timestamp: Double) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if timestamp - lastVideoSentTimestamp < videoMinInterval {
            return false
        }
        lastVideoSentTimestamp = timestamp
        return true
    }

    private func warnImageSizeZeroOnce() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if warnedImageSizeZero { return }
        warnedImageSizeZero = true
        print("rerun_log_lidar_frame_impl: image_size is 0 in WASM payload; skipping camera/image logging")
    }

    private func decodeKeypoints(
        execEnv: wasm_exec_env_t?,
        keypointsPointer: UnsafeMutableRawPointer?
    ) -> [Double]? {
        guard let execEnv = execEnv, let keypointsPointer = keypointsPointer else {
            return nil
        }
        guard let moduleInstance = wasm_runtime_get_module_inst(execEnv) else {
            return nil
        }

        let header = keypointsPointer.withMemoryRebound(to: UInt32.self, capacity: 3) { ptr -> (UInt32, UInt32, UInt32) in
            (ptr[0], ptr[1], ptr[2])
        }
        let beginOffset = header.0
        let endOffset = header.1

        if endOffset < beginOffset { return nil }
        let byteCount = Int(endOffset - beginOffset)
        if byteCount == 0 { return [] }
        print("rerun_log_camera_keypoints_impl: header begin=\(beginOffset) end=\(endOffset) bytes=\(byteCount)")

        let elementStride = MemoryLayout<Double>.size * 2
        if byteCount % elementStride != 0 { return nil }
        let elementCount = byteCount / elementStride
        if elementCount <= 0 { return [] }

        guard let beginNative = wasm_runtime_addr_app_to_native(moduleInstance, UInt64(beginOffset)) else {
            return nil
        }

        var nativeStart: UnsafeMutablePointer<UInt8>?
        var nativeEnd: UnsafeMutablePointer<UInt8>?
        let beginPtr = beginNative.assumingMemoryBound(to: UInt8.self)
        if !wasm_runtime_get_native_addr_range(moduleInstance, beginPtr, &nativeStart, &nativeEnd) {
            return nil
        }
        if let nativeEnd = nativeEnd {
            let baseAddr = UInt(bitPattern: beginPtr)
            let endAddr = UInt(bitPattern: nativeEnd)
            if baseAddr + UInt(byteCount) > endAddr {
                return nil
            }
        }

        let keypointPtr = beginPtr.withMemoryRebound(to: Double.self, capacity: elementCount * 2) { $0 }
        var output: [Double] = []
        output.reserveCapacity(elementCount * 2)
        for i in 0..<elementCount {
            let idx = i * 2
            output.append(keypointPtr[idx])
            output.append(keypointPtr[idx + 1])
        }
        return output
    }
}

private enum RerunMessage: Encodable {
    case points(timestamp: Double, points: [Float], colors: [UInt8]?)
    case pose(timestamp: Double, quaternion: [Double])
    case motors(timestamp: Double, left: Int, right: Int, holdMs: Int)
    case videoFrame(timestamp: Double, jpegBase64: String, width: Int, height: Int)
    case cameraKeypoints(timestamp: Double, keypoints: [Double])

    enum CodingKeys: String, CodingKey {
        case type, timestamp, points, colors, quaternion, left, right, hold_ms, jpeg_b64, keypoints
        case image_width, image_height
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .points(timestamp, points, colors):
            try container.encode("points3d", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(points, forKey: .points)
            try container.encodeIfPresent(colors, forKey: .colors)
        case let .pose(timestamp, quaternion):
            try container.encode("pose", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(quaternion, forKey: .quaternion)
        case let .motors(timestamp, left, right, holdMs):
            try container.encode("motors", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)
            try container.encode(holdMs, forKey: .hold_ms)
        case let .videoFrame(timestamp, jpegBase64, width, height):
            try container.encode("video_frame", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(jpegBase64, forKey: .jpeg_b64)
            try container.encode(width, forKey: .image_width)
            try container.encode(height, forKey: .image_height)
        case let .cameraKeypoints(timestamp, keypoints):
            try container.encode("camera_keypoints", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(keypoints, forKey: .keypoints)
        }
    }
}

final class RerunWebSocketClient {
    static let shared = RerunWebSocketClient()

    private static let serverURLDefaultsKey = "rerun_ws_server_url"
    static let defaultServerURLString = "ws://172.20.10.2:9877"
    private let queue = DispatchQueue(label: "com.roamr.rerun.ws")
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var isConnected = false

    private let encoder = JSONEncoder()

    var serverURLString = RerunWebSocketClient.defaultServerURLString

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey),
           !stored.isEmpty {
            serverURLString = normalizeURLString(stored)
        }
    }

    func logPoints(timestamp: Double, points: [Float], colors: [UInt8]?) {
        guard !points.isEmpty else { return }
        enqueue(.points(timestamp: timestamp, points: points, colors: colors))
    }

    func logPose(timestamp: Double, quaternion: [Double]) {
        guard quaternion.count == 4 else { return }
        enqueue(.pose(timestamp: timestamp, quaternion: quaternion))
    }

    func logMotors(timestamp: Double, left: Int, right: Int, holdMs: Int) {
        enqueue(.motors(timestamp: timestamp, left: left, right: right, holdMs: holdMs))
    }

    func logVideoFrame(timestamp: Double, jpegData: Data, width: Int, height: Int) {
        guard !jpegData.isEmpty else { return }
        enqueue(.videoFrame(
            timestamp: timestamp,
            jpegBase64: jpegData.base64EncodedString(),
            width: width,
            height: height
        ))
    }

    func logCameraKeypoints(timestamp: Double, keypoints: [Double]) {
        guard !keypoints.isEmpty else { return }
        enqueue(.cameraKeypoints(timestamp: timestamp, keypoints: keypoints))
    }

    private func enqueue(_ message: RerunMessage) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connectIfNeeded()
            self.send(message)
        }
    }

    private func connectIfNeeded() {
        if isConnected { return }
        let normalized = normalizeURLString(serverURLString)
        serverURLString = normalized
        guard let url = URL(string: normalized) else {
            print("Invalid rerun websocket URL: \(serverURLString)")
            return
        }

        print("Rerun websocket connecting to: \(serverURLString)")
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        isConnected = true
        listen()
    }

    private func send(_ message: RerunMessage) {
        guard let task = task else { return }
        guard let payload = try? encoder.encode(message),
              let payloadString = String(data: payload, encoding: .utf8) else {
            return
        }

        task.send(.string(payloadString)) { [weak self] error in
            if let error = error {
                print("Rerun websocket send error: \(error)")
                self?.isConnected = false
            }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.listen()
            case .failure(let error):
                print("Rerun websocket receive error: \(error)")
                self.isConnected = false
            }
        }
    }
}

extension RerunWebSocketClient {
    func updateServerURL(_ url: String) {
        queue.async {
            let normalized = self.normalizeURLString(url)
            guard normalized != self.serverURLString else { return }

            self.serverURLString = normalized
            UserDefaults.standard.set(normalized, forKey: Self.serverURLDefaultsKey)

            if self.isConnected {
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.isConnected = false
            }
        }
    }
}

private extension RerunWebSocketClient {
    func normalizeURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.hasPrefix("http://") {
            return "ws://\(trimmed.dropFirst("http://".count))"
        }
        if trimmed.hasPrefix("https://") {
            return "wss://\(trimmed.dropFirst("https://".count))"
        }
        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return trimmed
        }
        return "ws://\(trimmed)"
    }
}

func rerun_log_lidar_frame_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    WasmRerunTelemetryBridge.shared.handleWasmFrame(execEnv: exec_env, payloadPointer: ptr)
}

func rerun_log_camera_keypoints_impl(
    exec_env: wasm_exec_env_t?,
    ptr: UnsafeMutableRawPointer?,
    keypointsPtr: UnsafeMutableRawPointer?
) {
    WasmRerunTelemetryBridge.shared.handleWasmCameraKeypoints(
        execEnv: exec_env,
        payloadPointer: ptr,
        keypointsPointer: keypointsPtr
    )
}
