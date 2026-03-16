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
    static let layerIdOffset = dataSizeOffset + MemoryLayout<Int32>.size
    static let totalByteCount = layerIdOffset + MemoryLayout<Int32>.size
}

private enum WasmMapLayerId: Int32 {
    case composite = 0
    case base = 1
    case odometry = 2
    case planning = 3
    case frontiers = 4

    var websocketLayerName: String {
        switch self {
        case .composite:
            return "composite"
        case .base:
            return "base"
        case .odometry:
            return "odometry"
        case .planning:
            return "planning"
        case .frontiers:
            return "frontiers"
        }
    }
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
    let layerId: WasmMapLayerId
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

private enum SharedBinaryPointCloudProtocol {
    static let magic: [UInt8] = [0x52, 0x52, 0x42, 0x31]  // "RRB1"
    static let messageTypePoints: UInt8 = 1
    static let flagsOffset = 5
    static let timestampOffset = 8
    static let pointCountOffset = 16
    static let headerSize = 20
    static let hasColorsFlag: UInt8 = 1
}

private func makeSharedBinaryPointCloudPayload(
    timestamp: Double,
    pointsPointer: UnsafePointer<Float32>,
    pointCount: Int,
    colorsPointer: UnsafePointer<UInt8>?,
    colorsCount: Int
) -> Data? {
    guard pointCount > 0 else { return nil }

    let packedPointCount = pointCount * LidarCameraConstants.floatsPerPoint
    let pointsByteCount = packedPointCount * MemoryLayout<Float32>.size
    let hasColors = colorsPointer != nil && colorsCount >= packedPointCount
    let colorsByteCount = hasColors ? packedPointCount : 0
    let totalByteCount = SharedBinaryPointCloudProtocol.headerSize + pointsByteCount + colorsByteCount

    var payload = Data(count: totalByteCount)
    payload.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        let rawPointer = baseAddress.assumingMemoryBound(to: UInt8.self)

        SharedBinaryPointCloudProtocol.magic.withUnsafeBytes { magicBytes in
            if let magicBase = magicBytes.baseAddress {
                memcpy(rawPointer, magicBase, SharedBinaryPointCloudProtocol.magic.count)
            }
        }

        rawPointer[4] = SharedBinaryPointCloudProtocol.messageTypePoints
        rawPointer[SharedBinaryPointCloudProtocol.flagsOffset] = hasColors
            ? SharedBinaryPointCloudProtocol.hasColorsFlag
            : 0

        var reserved: UInt16 = 0
        withUnsafeBytes(of: &reserved) { bytes in
            if let src = bytes.baseAddress {
                memcpy(rawPointer.advanced(by: 6), src, MemoryLayout<UInt16>.size)
            }
        }

        var timestampBits = timestamp.bitPattern.littleEndian
        withUnsafeBytes(of: &timestampBits) { bytes in
            if let src = bytes.baseAddress {
                memcpy(
                    rawPointer.advanced(by: SharedBinaryPointCloudProtocol.timestampOffset),
                    src,
                    MemoryLayout<UInt64>.size
                )
            }
        }

        var pointCountLE = UInt32(pointCount).littleEndian
        withUnsafeBytes(of: &pointCountLE) { bytes in
            if let src = bytes.baseAddress {
                memcpy(
                    rawPointer.advanced(by: SharedBinaryPointCloudProtocol.pointCountOffset),
                    src,
                    MemoryLayout<UInt32>.size
                )
            }
        }

        memcpy(
            rawPointer.advanced(by: SharedBinaryPointCloudProtocol.headerSize),
            pointsPointer,
            pointsByteCount
        )

        if hasColors, let colorsPointer {
            memcpy(
                rawPointer.advanced(by: SharedBinaryPointCloudProtocol.headerSize + pointsByteCount),
                colorsPointer,
                colorsByteCount
            )
        }
    }

    return payload
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

private final class RGBAImageEncoder {
    func encode(
        rgbaPointer: UnsafeMutablePointer<UInt8>,
        byteCount: Int,
        width: Int,
        height: Int
    ) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let expectedCount = width * height * 4
        guard byteCount >= expectedCount else { return nil }

        let rgbaRawPointer = UnsafeMutableRawPointer(rgbaPointer)
        let rgbaData = Data(bytesNoCopy: rgbaRawPointer, count: expectedCount, deallocator: .none)
        guard let provider = CGDataProvider(data: rgbaData as CFData) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return outputData as Data
    }
}

private final class WasmRerunTelemetryBridge {
    static let shared = WasmRerunTelemetryBridge()

    private let videoMinInterval = 1.0 / 10.0
    private let processingLock = NSLock()
    private let stateLock = NSLock()
    private let jpegEncoder = RGBJpegEncoder(quality: 0.55)

    private let perfReportIntervalSec = 2.0
    private var perfWindowStartSec = CFAbsoluteTimeGetCurrent()
    private var perfFrameCount = 0
    private var perfDecodeTotalMs = 0.0
    private var perfPointEmitTotalMs = 0.0
    private var perfFrameTotalMs = 0.0

    private var lastVideoSentTimestamp: Double = 0.0
    private var warnedImageSizeZero = false

    private init() {}

    func handleWasmFrame(execEnv: wasm_exec_env_t?, payloadPointer: UnsafeMutableRawPointer?) {
        // Point-cloud preview now comes directly from AVManager so the WASM lidar bridge
        // stays off the hot path for scan ingestion.
        _ = execEnv
        _ = payloadPointer
        return
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
        let packedPointCount = (frame.pointsCount / LidarCameraConstants.floatsPerPoint)
            * LidarCameraConstants.floatsPerPoint
        guard packedPointCount >= LidarCameraConstants.floatsPerPoint else { return }

        let pointCount = packedPointCount / LidarCameraConstants.floatsPerPoint
        let requiredColorCount = pointCount * LidarCameraConstants.colorsPerPoint
        let hasUsableColors = frame.colorsCount >= requiredColorCount
        let colorsPointer: UnsafePointer<UInt8>? = hasUsableColors
            ? UnsafePointer(frame.colorsPointer)
            : nil
        let colorsCount = hasUsableColors ? requiredColorCount : 0
        guard let payload = makeSharedBinaryPointCloudPayload(
            timestamp: frame.timestamp,
            pointsPointer: UnsafePointer(frame.pointsPointer),
            pointCount: pointCount,
            colorsPointer: colorsPointer,
            colorsCount: colorsCount
        ) else {
            return
        }

        WebSocketManager.shared.broadcastPointCloudPayload(payload)
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

    private func recordPerf(decodeMs: Double, pointEmitMs: Double, frameTotalMs: Double) {
        perfFrameCount += 1
        perfDecodeTotalMs += decodeMs
        perfPointEmitTotalMs += pointEmitMs
        perfFrameTotalMs += frameTotalMs

        let nowSec = CFAbsoluteTimeGetCurrent()
        let elapsedSec = nowSec - perfWindowStartSec
        guard elapsedSec >= perfReportIntervalSec else { return }

        let frameCount = max(1, perfFrameCount)
        let fps = Double(perfFrameCount) / max(elapsedSec, 0.001)
        let avgDecodeMs = perfDecodeTotalMs / Double(frameCount)
        let avgPointEmitMs = perfPointEmitTotalMs / Double(frameCount)
        let avgFrameMs = perfFrameTotalMs / Double(frameCount)
        print(
            String(
                format: "[rerun][ios][bridge] fps=%.1f decode=%.3fms point_emit=%.3fms frame=%.3fms",
                fps,
                avgDecodeMs,
                avgPointEmitMs,
                avgFrameMs
            )
        )

        perfWindowStartSec = nowSec
        perfFrameCount = 0
        perfDecodeTotalMs = 0.0
        perfPointEmitTotalMs = 0.0
        perfFrameTotalMs = 0.0
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
        let layerIdValue = basePointer.advanced(by: WasmMapLayout.layerIdOffset)
            .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

        guard width > 0, height > 0, channels > 0, dataPtr > 0, dataSize > 0 else {
            return nil
        }
        guard let layerId = WasmMapLayerId(rawValue: layerIdValue) else {
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
            dataCount: Int(dataSize),
            layerId: layerId
        )
    }

    private func logMapImage(_ frame: WasmMapFrameView) {
        switch frame.layerId {
        case .composite:
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

            WasmManager.shared.updateMapPreview(jpegData: jpegData, timestamp: frame.timestamp)
            WebSocketManager.shared.publishMapFrame(timestamp: frame.timestamp, jpegData: jpegData)
        case .base, .odometry, .planning, .frontiers:
            guard frame.channels >= 4 else { return }
            WebSocketManager.shared.publishMapLayerFrame(
                timestamp: frame.timestamp,
                layer: frame.layerId.websocketLayerName,
                width: frame.width,
                height: frame.height,
                channels: frame.channels,
                rgbaPointer: UnsafePointer(frame.dataPointer),
                dataCount: frame.dataCount
            )
        }
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

private enum RerunBinaryPointsProtocol {
    static let magic: [UInt8] = [0x52, 0x52, 0x42, 0x31]  // "RRB1"
    static let messageTypePoints: UInt8 = 1
    static let flagsOffset = 5
    static let timestampOffset = 8
    static let pointCountOffset = 16
    static let headerSize = 20
    static let hasColorsFlag: UInt8 = 1
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
    private let maxPending = 6

    private let encoder = JSONEncoder()
    private let useBinaryPointCloudTransport = true

    private let perfReportIntervalSec = 2.0
    private var perfWindowStartSec = CFAbsoluteTimeGetCurrent()
    private var perfBinaryEnqueued = 0
    private var perfBinaryDropped = 0
    private var perfBinaryBytes = 0
    private var perfBinarySendCount = 0
    private var perfBinarySendTotalMs = 0.0
    private var perfPendingHighWatermark = 0

    var serverURLString = RerunWebSocketClient.defaultServerURLString

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey),
           !stored.isEmpty {
            serverURLString = normalizeURLString(stored)
        }
    }

    func logPoints(timestamp: Double, points: [Float], colors: [UInt8]?) {
        guard !points.isEmpty else { return }
        if useBinaryPointCloudTransport,
           let binaryPayload = makeBinaryPointCloudPayload(
            timestamp: timestamp,
            points: points,
            colors: colors
           ) {
            enqueueBinaryPointCloud(binaryPayload)
            return
        }
        enqueue(.points(timestamp: timestamp, points: points, colors: colors))
    }

    func logPointsFromWasm(
        timestamp: Double,
        pointsPointer: UnsafePointer<Float32>,
        pointCount: Int,
        colorsPointer: UnsafePointer<UInt8>?,
        colorsCount: Int
    ) {
        guard pointCount > 0 else { return }
        if useBinaryPointCloudTransport,
           let binaryPayload = makeBinaryPointCloudPayload(
            timestamp: timestamp,
            pointsPointer: pointsPointer,
            pointCount: pointCount,
            colorsPointer: colorsPointer,
            colorsCount: colorsCount
           ) {
            enqueueBinaryPointCloud(binaryPayload)
            return
        }

        let floatCount = pointCount * LidarCameraConstants.floatsPerPoint
        let fallbackPoints = Array(
            UnsafeBufferPointer(start: pointsPointer, count: floatCount)
        )
        var fallbackColors: [UInt8]?
        if let colorsPointer, colorsCount >= floatCount {
            fallbackColors = Array(
                UnsafeBufferPointer(start: colorsPointer, count: floatCount)
            )
        }
        enqueue(.points(timestamp: timestamp, points: fallbackPoints, colors: fallbackColors))
    }

    func logBinaryPointCloud(_ payload: Data) {
        guard !payload.isEmpty else { return }
        enqueueBinaryPointCloud(payload)
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

    private func enqueueBinaryPointCloud(_ payload: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.shouldDropPointCloud() else {
                self.perfBinaryDropped += 1
                self.maybeReportBinaryPerf()
                return
            }
            self.pendingCount += 1
            self.perfBinaryEnqueued += 1
            self.perfBinaryBytes += payload.count
            self.perfPendingHighWatermark = max(self.perfPendingHighWatermark, self.pendingCount)
            self.maybeReportBinaryPerf()
            self.connectIfNeeded()
            self.sendBinary(payload)
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

    private func sendBinary(_ payload: Data) {
        let sendStartSec = CFAbsoluteTimeGetCurrent()
        guard let task = task else {
            queue.async { [weak self] in
                self?.decrementPending()
                self?.maybeReportBinaryPerf()
            }
            return
        }

        task.send(.data(payload)) { [weak self] error in
            let sendDurationMs = (CFAbsoluteTimeGetCurrent() - sendStartSec) * 1000.0
            self?.queue.async { [weak self] in
                self?.decrementPending()
                self?.perfBinarySendCount += 1
                self?.perfBinarySendTotalMs += sendDurationMs
                self?.maybeReportBinaryPerf()
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
        case .points, .videoFrame:
            return true
        case .mapFrame, .pose:
            return pendingCount > maxPending * 2
        case .motors, .imu:
            return pendingCount > maxPending * 3
        default:
            return pendingCount > maxPending
        }
    }

    private func shouldDropPointCloud() -> Bool {
        pendingCount >= maxPending
    }

    private func makeBinaryPointCloudPayload(
        timestamp: Double,
        points: [Float],
        colors: [UInt8]?
    ) -> Data? {
        guard points.count >= 3 else { return nil }
        let pointCount = points.count / 3
        let packedPointCount = pointCount * 3
        guard packedPointCount > 0 else { return nil }

        let pointsByteCount = packedPointCount * MemoryLayout<Float32>.size
        let hasColors = (colors?.count ?? 0) >= packedPointCount
        let colorsByteCount = hasColors ? packedPointCount : 0
        let totalByteCount = RerunBinaryPointsProtocol.headerSize + pointsByteCount + colorsByteCount

        var payload = Data(count: totalByteCount)
        payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let rawPointer = baseAddress.assumingMemoryBound(to: UInt8.self)

            RerunBinaryPointsProtocol.magic.withUnsafeBytes { magicBytes in
                if let magicBase = magicBytes.baseAddress {
                    memcpy(rawPointer, magicBase, RerunBinaryPointsProtocol.magic.count)
                }
            }

            rawPointer[4] = RerunBinaryPointsProtocol.messageTypePoints
            rawPointer[RerunBinaryPointsProtocol.flagsOffset] = hasColors
                ? RerunBinaryPointsProtocol.hasColorsFlag
                : 0
            var reserved: UInt16 = 0
            withUnsafeBytes(of: &reserved) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(rawPointer.advanced(by: 6), src, MemoryLayout<UInt16>.size)
                }
            }
            var timestampBits = timestamp.bitPattern.littleEndian
            withUnsafeBytes(of: &timestampBits) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RerunBinaryPointsProtocol.timestampOffset),
                        src,
                        MemoryLayout<UInt64>.size
                    )
                }
            }
            var pointCountLE = UInt32(pointCount).littleEndian
            withUnsafeBytes(of: &pointCountLE) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RerunBinaryPointsProtocol.pointCountOffset),
                        src,
                        MemoryLayout<UInt32>.size
                    )
                }
            }

            points.withUnsafeBytes { pointBytes in
                if let pointsBase = pointBytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RerunBinaryPointsProtocol.headerSize),
                        pointsBase,
                        pointsByteCount
                    )
                }
            }

            if hasColors, let colors {
                colors.withUnsafeBytes { colorBytes in
                    if let colorsBase = colorBytes.baseAddress {
                        memcpy(
                            rawPointer.advanced(by: RerunBinaryPointsProtocol.headerSize + pointsByteCount),
                            colorsBase,
                            colorsByteCount
                        )
                    }
                }
            }
        }
        return payload
    }

    private func makeBinaryPointCloudPayload(
        timestamp: Double,
        pointsPointer: UnsafePointer<Float32>,
        pointCount: Int,
        colorsPointer: UnsafePointer<UInt8>?,
        colorsCount: Int
    ) -> Data? {
        guard pointCount > 0 else { return nil }
        let packedPointCount = pointCount * LidarCameraConstants.floatsPerPoint
        guard packedPointCount > 0 else { return nil }

        let pointsByteCount = packedPointCount * MemoryLayout<Float32>.size
        let hasColors = colorsPointer != nil && colorsCount >= packedPointCount
        let colorsByteCount = hasColors ? packedPointCount : 0
        let totalByteCount = RerunBinaryPointsProtocol.headerSize + pointsByteCount + colorsByteCount

        var payload = Data(count: totalByteCount)
        payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let rawPointer = baseAddress.assumingMemoryBound(to: UInt8.self)

            RerunBinaryPointsProtocol.magic.withUnsafeBytes { magicBytes in
                if let magicBase = magicBytes.baseAddress {
                    memcpy(rawPointer, magicBase, RerunBinaryPointsProtocol.magic.count)
                }
            }

            rawPointer[4] = RerunBinaryPointsProtocol.messageTypePoints
            rawPointer[RerunBinaryPointsProtocol.flagsOffset] = hasColors
                ? RerunBinaryPointsProtocol.hasColorsFlag
                : 0
            var reserved: UInt16 = 0
            withUnsafeBytes(of: &reserved) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(rawPointer.advanced(by: 6), src, MemoryLayout<UInt16>.size)
                }
            }
            var timestampBits = timestamp.bitPattern.littleEndian
            withUnsafeBytes(of: &timestampBits) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RerunBinaryPointsProtocol.timestampOffset),
                        src,
                        MemoryLayout<UInt64>.size
                    )
                }
            }
            var pointCountLE = UInt32(pointCount).littleEndian
            withUnsafeBytes(of: &pointCountLE) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RerunBinaryPointsProtocol.pointCountOffset),
                        src,
                        MemoryLayout<UInt32>.size
                    )
                }
            }

            memcpy(
                rawPointer.advanced(by: RerunBinaryPointsProtocol.headerSize),
                pointsPointer,
                pointsByteCount
            )

            if hasColors, let colorsPointer {
                memcpy(
                    rawPointer.advanced(by: RerunBinaryPointsProtocol.headerSize + pointsByteCount),
                    colorsPointer,
                    colorsByteCount
                )
            }
        }
        return payload
    }

    private func maybeReportBinaryPerf() {
        let nowSec = CFAbsoluteTimeGetCurrent()
        let elapsedSec = nowSec - perfWindowStartSec
        guard elapsedSec >= perfReportIntervalSec else { return }

        let enqueueRate = Double(perfBinaryEnqueued) / max(elapsedSec, 0.001)
        let txMBps = Double(perfBinaryBytes) / max(elapsedSec, 0.001) / 1_000_000.0
        let avgSendMs: Double
        if perfBinarySendCount > 0 {
            avgSendMs = perfBinarySendTotalMs / Double(perfBinarySendCount)
        } else {
            avgSendMs = 0.0
        }
        print(
            String(
                format: "[rerun][ios][ws] enqueue=%.1f/s dropped=%d tx=%.2fMB/s send=%.3fms pending_hw=%d",
                enqueueRate,
                perfBinaryDropped,
                txMBps,
                avgSendMs,
                perfPendingHighWatermark
            )
        )

        perfWindowStartSec = nowSec
        perfBinaryEnqueued = 0
        perfBinaryDropped = 0
        perfBinaryBytes = 0
        perfBinarySendCount = 0
        perfBinarySendTotalMs = 0.0
        perfPendingHighWatermark = pendingCount
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
    _ = exec_env
    _ = ptr
}

func rerun_log_pose_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    _ = exec_env
    _ = ptr
}

func rerun_log_pose_wheel_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    _ = exec_env
    _ = ptr
}
