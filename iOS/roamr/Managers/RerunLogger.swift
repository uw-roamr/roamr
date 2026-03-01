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

    static let pointsFrameIdOffset = imageSizeOffset + imageSizeBytes
    static let imageFrameIdOffset = pointsFrameIdOffset + MemoryLayout<Int32>.size
    static let totalByteCount = imageFrameIdOffset + MemoryLayout<Int32>.size
}

private struct WasmLidarFrameView {
    let timestamp: Double
    let pointsPointer: UnsafeMutablePointer<Float32>
    let pointsCount: Int
    let colorsPointer: UnsafeMutablePointer<UInt8>
    let colorsCount: Int
    let imagePointer: UnsafeMutablePointer<UInt8>
    let imageCount: Int
    let pointsFrameId: Int32
    let imageFrameId: Int32
}

private enum WasmMapLayout {
    static let timestampOffset = 0
    static let widthOffset = timestampOffset + MemoryLayout<Double>.size
    static let heightOffset = widthOffset + MemoryLayout<Int32>.size
    static let channelsOffset = heightOffset + MemoryLayout<Int32>.size
    static let dataPtrOffset = channelsOffset + MemoryLayout<Int32>.size
    static let dataSizeOffset = dataPtrOffset + MemoryLayout<UInt32>.size
    static let totalByteCount = dataSizeOffset + MemoryLayout<Int32>.size
}

private enum WasmImuLayout {
    static let timestampOffset = 0
    static let accelOffset = timestampOffset + MemoryLayout<Double>.size
    static let accelCount = 3
    static let gyroOffset = accelOffset + accelCount * MemoryLayout<Double>.size
    static let gyroCount = 3
    static let frameIdOffset = gyroOffset + gyroCount * MemoryLayout<Double>.size
    static let totalByteCount = frameIdOffset + MemoryLayout<Int32>.size
}

private enum WasmPoseLayout {
    static let timestampOffset = 0
    static let translationOffset = timestampOffset + MemoryLayout<Double>.size
    static let translationCount = 3
    static let quaternionOffset = translationOffset + translationCount * MemoryLayout<Double>.size
    static let quaternionCount = 4
    static let totalByteCount = quaternionOffset + quaternionCount * MemoryLayout<Double>.size
}

private struct WasmMapFrameView {
    let timestamp: Double
    let width: Int
    let height: Int
    let channels: Int
    let dataPointer: UnsafeMutablePointer<UInt8>
    let dataCount: Int
}

private struct WasmImuView {
    let timestamp: Double
    let accel: SIMD3<Double>
    let gyro: SIMD3<Double>
    let frameId: Int32
}

private struct WasmPoseView {
    let timestamp: Double
    let translation: SIMD3<Double>
    let quaternion: SIMD4<Double>
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
    private let videoMinInterval = 1.0 / 10.0
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

        guard let frame = decodeFrame(execEnv: execEnv, payloadPointer: payloadPointer) else {
            return
        }
        logPointCloud(frame)
        logCameraImage(frame)
    }

    private func decodeFrame(
        execEnv: wasm_exec_env_t?,
        payloadPointer: UnsafeMutableRawPointer?
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
        if pointsCount < 3 { return nil }

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

        let pointsFrameId = basePointer
            .advanced(by: WasmLidarLayout.pointsFrameIdOffset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let imageFrameId = basePointer
            .advanced(by: WasmLidarLayout.imageFrameIdOffset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

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
            imageCount: imageCount,
            pointsFrameId: pointsFrameId,
            imageFrameId: imageFrameId
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

        var outputColors: [UInt8]?
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
            jpegData: jpegData
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
}

private final class WasmRerunMapBridge {
    static let shared = WasmRerunMapBridge()

    private let processingLock = NSLock()
    private let jpegEncoder = RGBJpegEncoder(quality: 0.7)
    private var rgbScratch: [UInt8] = []

    private init() {}

    func handleWasmMapFrame(execEnv: wasm_exec_env_t?, payloadPointer: UnsafeMutableRawPointer?) {
        processingLock.lock()
        defer { processingLock.unlock() }

        guard let frame = decodeFrame(execEnv: execEnv, payloadPointer: payloadPointer) else {
            return
        }
        logMapImage(frame)
    }

    private func decodeFrame(
        execEnv: wasm_exec_env_t?,
        payloadPointer: UnsafeMutableRawPointer?
    ) -> WasmMapFrameView? {
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
            if baseAddress + UInt(WasmMapLayout.totalByteCount) > endAddress {
                return nil
            }
        }

        let timestamp = basePointer.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee }
        let width = basePointer.advanced(by: WasmMapLayout.widthOffset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let height = basePointer.advanced(by: WasmMapLayout.heightOffset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let channels = basePointer.advanced(by: WasmMapLayout.channelsOffset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let dataPtr = basePointer.advanced(by: WasmMapLayout.dataPtrOffset)
            .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        let dataSize = basePointer.advanced(by: WasmMapLayout.dataSizeOffset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

        guard width > 0, height > 0, channels > 0, dataPtr > 0, dataSize > 0 else {
            return nil
        }

        guard let nativePtr = wasm_runtime_addr_app_to_native(moduleInstance, UInt64(dataPtr)) else {
            return nil
        }
        let dataPointer = nativePtr.assumingMemoryBound(to: UInt8.self)
        guard wasm_runtime_validate_native_addr(moduleInstance, dataPointer, UInt64(dataSize)) else {
            return nil
        }

        return WasmMapFrameView(
            timestamp: timestamp,
            width: Int(width),
            height: Int(height),
            channels: Int(channels),
            dataPointer: dataPointer,
            dataCount: Int(dataSize)
        )
    }

    private func logMapImage(_ frame: WasmMapFrameView) {
        let pixelCount = frame.width * frame.height
        guard pixelCount > 0, frame.channels >= 3 else { return }

        let expectedCount = pixelCount * frame.channels
        guard frame.dataCount >= expectedCount else { return }

        let rgbCount = pixelCount * 3
        if rgbScratch.count != rgbCount {
            rgbScratch = [UInt8](repeating: 0, count: rgbCount)
        }

        var srcIndex = 0
        var dstIndex = 0
        while dstIndex < rgbCount {
            rgbScratch[dstIndex] = frame.dataPointer[srcIndex]
            rgbScratch[dstIndex + 1] = frame.dataPointer[srcIndex + 1]
            rgbScratch[dstIndex + 2] = frame.dataPointer[srcIndex + 2]
            dstIndex += 3
            srcIndex += frame.channels
        }

        let jpegData: Data? = rgbScratch.withUnsafeMutableBufferPointer { buffer -> Data? in
            guard let base = buffer.baseAddress else { return nil }
            return jpegEncoder.encode(
                rgbPointer: base,
                byteCount: buffer.count,
                width: frame.width,
                height: frame.height
            )
        }
        guard let jpegData else {
            return
        }

        RerunWebSocketClient.shared.logMapFrame(timestamp: frame.timestamp, jpegData: jpegData)
    }
}

private enum RerunMessage: Encodable {
    case points(timestamp: Double, points: [Float], colors: [UInt8]?)
    case pose(timestamp: Double, translation: [Double], quaternion: [Double], source: String)
    case imu(timestamp: Double, accel: [Double], gyro: [Double], frameId: Int32)
    case motors(timestamp: Double, left: Int, right: Int, holdMs: Int)
    case videoFrame(timestamp: Double, jpegBase64: String)
    case mapFrame(timestamp: Double, jpegBase64: String)

    enum CodingKeys: String, CodingKey {
        case type, timestamp, points, colors, translation, quaternion, pose_source, accel, gyro, frame_id, left, right, hold_ms, jpeg_b64
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .points(timestamp, points, colors):
            try container.encode("points3d", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(points, forKey: .points)
            try container.encodeIfPresent(colors, forKey: .colors)
        case let .pose(timestamp, translation, quaternion, source):
            try container.encode("pose", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(translation, forKey: .translation)
            try container.encode(quaternion, forKey: .quaternion)
            try container.encode(source, forKey: .pose_source)
        case let .imu(timestamp, accel, gyro, frameId):
            try container.encode("imu", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(accel, forKey: .accel)
            try container.encode(gyro, forKey: .gyro)
            try container.encode(frameId, forKey: .frame_id)
        case let .motors(timestamp, left, right, holdMs):
            try container.encode("motors", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)
            try container.encode(holdMs, forKey: .hold_ms)
        case let .videoFrame(timestamp, jpegBase64):
            try container.encode("video_frame", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(jpegBase64, forKey: .jpeg_b64)
        case let .mapFrame(timestamp, jpegBase64):
            try container.encode("map_frame", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(jpegBase64, forKey: .jpeg_b64)
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
    private var pendingCount = 0
    private let maxPending = 2

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
        enqueue(.pose(timestamp: timestamp, translation: [0.0, 0.0, 0.0], quaternion: quaternion, source: "imu"))
    }

    func logPose(timestamp: Double, translation: [Double], quaternion: [Double]) {
        logPose(timestamp: timestamp, translation: translation, quaternion: quaternion, source: "imu")
    }

    func logPose(timestamp: Double, translation: [Double], quaternion: [Double], source: String) {
        guard translation.count == 3, quaternion.count == 4 else { return }
        enqueue(.pose(timestamp: timestamp, translation: translation, quaternion: quaternion, source: source))
    }

    func logImu(timestamp: Double, accel: [Double], gyro: [Double], frameId: Int32) {
        guard accel.count == 3, gyro.count == 3 else { return }
        enqueue(.imu(timestamp: timestamp, accel: accel, gyro: gyro, frameId: frameId))
    }

    func logMotors(timestamp: Double, left: Int, right: Int, holdMs: Int) {
        enqueue(.motors(timestamp: timestamp, left: left, right: right, holdMs: holdMs))
    }

    func logVideoFrame(timestamp: Double, jpegData: Data) {
        guard !jpegData.isEmpty else { return }
        enqueue(.videoFrame(timestamp: timestamp, jpegBase64: jpegData.base64EncodedString()))
    }

    func logMapFrame(timestamp: Double, jpegData: Data) {
        guard !jpegData.isEmpty else { return }
        enqueue(.mapFrame(timestamp: timestamp, jpegBase64: jpegData.base64EncodedString()))
    }

    private func enqueue(_ message: RerunMessage) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.shouldDrop(message) {
                return
            }
            self.pendingCount += 1
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
            queue.async { [weak self] in
                self?.decrementPending()
            }
            return
        }

        task.send(.string(payloadString)) { [weak self] error in
            self?.queue.async { [weak self] in
                self?.decrementPending()
            }
            if let error = error {
                print("Rerun websocket send error: \(error)")
                self?.markDisconnected()
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
                self.markDisconnected()
            }
        }
    }

    private func markDisconnected() {
        isConnected = false
        task = nil
    }

    private func decrementPending() {
        if pendingCount > 0 {
            pendingCount -= 1
        }
    }

    private func shouldDrop(_ message: RerunMessage) -> Bool {
        if pendingCount < maxPending {
            return false
        }
        switch message {
        case .motors, .imu:
            return pendingCount > maxPending * 2
        default:
            return true
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

func rerun_log_map_frame_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    WasmRerunMapBridge.shared.handleWasmMapFrame(execEnv: exec_env, payloadPointer: ptr)
}

func rerun_log_imu_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let exec_env = exec_env, let ptr = ptr else { return }

    let basePointer = ptr.assumingMemoryBound(to: UInt8.self)
    guard let moduleInstance = wasm_runtime_get_module_inst(exec_env) else {
        return
    }
    var nativeStart: UnsafeMutablePointer<UInt8>?
    var nativeEnd: UnsafeMutablePointer<UInt8>?
    guard wasm_runtime_get_native_addr_range(moduleInstance, basePointer, &nativeStart, &nativeEnd) else {
        return
    }

    if let nativeEnd = nativeEnd {
        let baseAddress = UInt(bitPattern: basePointer)
        let endAddress = UInt(bitPattern: nativeEnd)
        if baseAddress + UInt(WasmImuLayout.totalByteCount) > endAddress {
            return
        }
    }

    let timestamp = basePointer.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee }
    let accPtr = basePointer.advanced(by: WasmImuLayout.accelOffset)
    let gyroPtr = basePointer.advanced(by: WasmImuLayout.gyroOffset)
    let accel = accPtr.withMemoryRebound(to: Double.self, capacity: WasmImuLayout.accelCount) {
        SIMD3<Double>($0[0], $0[1], $0[2])
    }
    let gyro = gyroPtr.withMemoryRebound(to: Double.self, capacity: WasmImuLayout.gyroCount) {
        SIMD3<Double>($0[0], $0[1], $0[2])
    }
    let frameId = basePointer.advanced(by: WasmImuLayout.frameIdOffset)
        .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

    RerunWebSocketClient.shared.logImu(
        timestamp: timestamp,
        accel: [accel.x, accel.y, accel.z],
        gyro: [gyro.x, gyro.y, gyro.z],
        frameId: frameId
    )
}

func rerun_log_pose_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let exec_env = exec_env, let ptr = ptr else { return }

    let basePointer = ptr.assumingMemoryBound(to: UInt8.self)
    guard let moduleInstance = wasm_runtime_get_module_inst(exec_env) else {
        return
    }
    var nativeStart: UnsafeMutablePointer<UInt8>?
    var nativeEnd: UnsafeMutablePointer<UInt8>?
    guard wasm_runtime_get_native_addr_range(moduleInstance, basePointer, &nativeStart, &nativeEnd) else {
        return
    }

    if let nativeEnd = nativeEnd {
        let baseAddress = UInt(bitPattern: basePointer)
        let endAddress = UInt(bitPattern: nativeEnd)
        if baseAddress + UInt(WasmPoseLayout.totalByteCount) > endAddress {
            return
        }
    }

    let timestamp = basePointer.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee }
    let translationPtr = basePointer.advanced(by: WasmPoseLayout.translationOffset)
    let quatPtr = basePointer.advanced(by: WasmPoseLayout.quaternionOffset)
    let translation = translationPtr.withMemoryRebound(to: Double.self, capacity: WasmPoseLayout.translationCount) {
        SIMD3<Double>($0[0], $0[1], $0[2])
    }
    let quaternion = quatPtr.withMemoryRebound(to: Double.self, capacity: WasmPoseLayout.quaternionCount) {
        SIMD4<Double>($0[0], $0[1], $0[2], $0[3])
    }

    RerunWebSocketClient.shared.logPose(
        timestamp: timestamp,
        translation: [translation.x, translation.y, translation.z],
        quaternion: [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
        source: "imu"
    )
}

func rerun_log_pose_wheel_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let exec_env = exec_env, let ptr = ptr else { return }

    let basePointer = ptr.assumingMemoryBound(to: UInt8.self)
    guard let moduleInstance = wasm_runtime_get_module_inst(exec_env) else {
        return
    }
    var nativeStart: UnsafeMutablePointer<UInt8>?
    var nativeEnd: UnsafeMutablePointer<UInt8>?
    guard wasm_runtime_get_native_addr_range(moduleInstance, basePointer, &nativeStart, &nativeEnd) else {
        return
    }

    if let nativeEnd = nativeEnd {
        let baseAddress = UInt(bitPattern: basePointer)
        let endAddress = UInt(bitPattern: nativeEnd)
        if baseAddress + UInt(WasmPoseLayout.totalByteCount) > endAddress {
            return
        }
    }

    let timestamp = basePointer.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee }
    let translationPtr = basePointer.advanced(by: WasmPoseLayout.translationOffset)
    let quatPtr = basePointer.advanced(by: WasmPoseLayout.quaternionOffset)
    let translation = translationPtr.withMemoryRebound(to: Double.self, capacity: WasmPoseLayout.translationCount) {
        SIMD3<Double>($0[0], $0[1], $0[2])
    }
    let quaternion = quatPtr.withMemoryRebound(to: Double.self, capacity: WasmPoseLayout.quaternionCount) {
        SIMD4<Double>($0[0], $0[1], $0[2], $0[3])
    }

    RerunWebSocketClient.shared.logPose(
        timestamp: timestamp,
        translation: [translation.x, translation.y, translation.z],
        quaternion: [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
        source: "wheel_odometry"
    )
}
