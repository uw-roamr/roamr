//
//  ModelBridge.swift
//  roamr
//
//  Fixed-layout host ABI for dynamic model loading and latest-frame inference.
//

import Foundation

private enum MlBridgeLayout {
    static let manifestPathCapacity = 512

    static let openModelIdOffset = manifestPathCapacity
    static let openStatusOffset = openModelIdOffset + MemoryLayout<Int32>.size
    static let openRequestSize = openStatusOffset + MemoryLayout<Int32>.size

    static let closeModelIdOffset = 0
    static let closeStatusOffset = MemoryLayout<Int32>.size
    static let closeRequestSize = closeStatusOffset + MemoryLayout<Int32>.size

    static let runModelIdOffset = 0
    static let runStatusOffset = 4
    static let runFrameTimestampOffset = 8
    static let runImageWidthOffset = 16
    static let runImageHeightOffset = 20
    static let runDetectionCountOffset = 24
    static let runDetectionsOffset = 28

    static let detectionClassIdOffset = 0
    static let detectionScoreOffset = 4
    static let detectionXMinOffset = 8
    static let detectionYMinOffset = 12
    static let detectionXMaxOffset = 16
    static let detectionYMaxOffset = 20
    static let detectionStride = 24
    static let maxDetections = 32
    static let runRequestSize = runDetectionsOffset + (maxDetections * detectionStride)
}

private func validatedNativeBasePointer(
    execEnv: wasm_exec_env_t?,
    ptr: UnsafeMutableRawPointer?,
    requiredBytes: Int
) -> UnsafeMutablePointer<UInt8>? {
    guard let execEnv, let ptr else {
        return nil
    }

    let basePtr = ptr.assumingMemoryBound(to: UInt8.self)
    guard let moduleInstance = wasm_runtime_get_module_inst(execEnv) else {
        return nil
    }

    var nativeStart: UnsafeMutablePointer<UInt8>?
    var nativeEnd: UnsafeMutablePointer<UInt8>?
    guard wasm_runtime_get_native_addr_range(moduleInstance, basePtr, &nativeStart, &nativeEnd) else {
        return nil
    }

    if let nativeEnd {
        let baseAddress = UInt(bitPattern: basePtr)
        let endAddress = UInt(bitPattern: nativeEnd)
        if baseAddress + UInt(requiredBytes) > endAddress {
            return nil
        }
    }

    return basePtr
}

private func readInt32(from basePtr: UnsafeMutablePointer<UInt8>, offset: Int) -> Int32 {
    basePtr.advanced(by: offset).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
}

private func writeInt32(_ value: Int32, to basePtr: UnsafeMutablePointer<UInt8>, offset: Int) {
    basePtr.advanced(by: offset).withMemoryRebound(to: Int32.self, capacity: 1) { rebounded in
        rebounded.pointee = value
    }
}

private func writeDouble(_ value: Double, to basePtr: UnsafeMutablePointer<UInt8>, offset: Int) {
    basePtr.advanced(by: offset).withMemoryRebound(to: Double.self, capacity: 1) { rebounded in
        rebounded.pointee = value
    }
}

private func readFixedCString(
    from basePtr: UnsafeMutablePointer<UInt8>,
    offset: Int,
    capacity: Int
) -> String {
    let textStart = basePtr.advanced(by: offset)
    let bytes = UnsafeBufferPointer(start: textStart, count: capacity)
    let count = bytes.firstIndex(of: 0) ?? capacity
    return String(decoding: bytes.prefix(count), as: UTF8.self)
}

func ml_open_model_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let basePtr = validatedNativeBasePointer(
        execEnv: exec_env,
        ptr: ptr,
        requiredBytes: MlBridgeLayout.openRequestSize
    ) else {
        return
    }

    let manifestPath = readFixedCString(
        from: basePtr,
        offset: 0,
        capacity: MlBridgeLayout.manifestPathCapacity
    )
    let result = ModelRunner.shared.openModel(manifestPath: manifestPath)
    writeInt32(result.modelId, to: basePtr, offset: MlBridgeLayout.openModelIdOffset)
    writeInt32(result.status.rawValue, to: basePtr, offset: MlBridgeLayout.openStatusOffset)
}

func ml_run_latest_camera_frame_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let basePtr = validatedNativeBasePointer(
        execEnv: exec_env,
        ptr: ptr,
        requiredBytes: MlBridgeLayout.runRequestSize
    ) else {
        return
    }

    let modelId = readInt32(from: basePtr, offset: MlBridgeLayout.runModelIdOffset)
    let result = ModelRunner.shared.runLatestCameraFrame(modelId: modelId)

    writeInt32(result.status.rawValue, to: basePtr, offset: MlBridgeLayout.runStatusOffset)
    writeDouble(result.frameTimestamp, to: basePtr, offset: MlBridgeLayout.runFrameTimestampOffset)
    writeInt32(result.imageWidth, to: basePtr, offset: MlBridgeLayout.runImageWidthOffset)
    writeInt32(result.imageHeight, to: basePtr, offset: MlBridgeLayout.runImageHeightOffset)

    let detectionCount = min(result.detections.count, MlBridgeLayout.maxDetections)
    writeInt32(Int32(detectionCount), to: basePtr, offset: MlBridgeLayout.runDetectionCountOffset)

    for detectionIndex in 0..<MlBridgeLayout.maxDetections {
        let detectionBase = MlBridgeLayout.runDetectionsOffset + (detectionIndex * MlBridgeLayout.detectionStride)
        let detection = detectionIndex < detectionCount
            ? result.detections[detectionIndex]
            : ModelDetection(classId: 0, score: 0, xMin: 0, yMin: 0, xMax: 0, yMax: 0)

        writeInt32(detection.classId, to: basePtr, offset: detectionBase + MlBridgeLayout.detectionClassIdOffset)
        basePtr.advanced(by: detectionBase + MlBridgeLayout.detectionScoreOffset)
            .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee = detection.score }
        basePtr.advanced(by: detectionBase + MlBridgeLayout.detectionXMinOffset)
            .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee = detection.xMin }
        basePtr.advanced(by: detectionBase + MlBridgeLayout.detectionYMinOffset)
            .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee = detection.yMin }
        basePtr.advanced(by: detectionBase + MlBridgeLayout.detectionXMaxOffset)
            .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee = detection.xMax }
        basePtr.advanced(by: detectionBase + MlBridgeLayout.detectionYMaxOffset)
            .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee = detection.yMax }
    }
}

func ml_close_model_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let basePtr = validatedNativeBasePointer(
        execEnv: exec_env,
        ptr: ptr,
        requiredBytes: MlBridgeLayout.closeRequestSize
    ) else {
        return
    }

    let modelId = readInt32(from: basePtr, offset: MlBridgeLayout.closeModelIdOffset)
    let status = ModelRunner.shared.closeModel(modelId: modelId)
    writeInt32(status.rawValue, to: basePtr, offset: MlBridgeLayout.closeStatusOffset)
}
