//
//  WasmManager.swift
//  roamr
//
//  Created by Thomason Zhou on 2025-11-23.
//

import Combine
import Foundation

typealias CFunction = @convention(c) (wasm_exec_env_t?, UnsafeMutableRawPointer?) -> Void

private let wasmTextLogMaxBytes = 255
private let wasmTextLogPayloadSize = MemoryLayout<UInt32>.size + wasmTextLogMaxBytes + 1

struct WasmSensorConfig: Equatable {
    var imuEnabled: Bool
    var wheelOdometryEnabled: Bool
    var lidarPointsEnabled: Bool
    var pointColorsEnabled: Bool
    var cameraImageEnabled: Bool

    static let `default` = WasmSensorConfig(
        imuEnabled: true,
        wheelOdometryEnabled: true,
        lidarPointsEnabled: true,
        pointColorsEnabled: false,
        cameraImageEnabled: true
    )
}

final class WasmManager: ObservableObject {
    static let shared = WasmManager()
    private static let maxWasmThreads: UInt32 = 8
    private static let maxLogLines = 200
    private static let sensorImuEnabledDefaultsKey = "com.roamr.wasm.sensor.imuEnabled"
    private static let sensorWheelOdometryEnabledDefaultsKey = "com.roamr.wasm.sensor.wheelOdometryEnabled"
    private static let sensorLidarPointsEnabledDefaultsKey = "com.roamr.wasm.sensor.lidarPointsEnabled"
    private static let sensorPointColorsEnabledDefaultsKey = "com.roamr.wasm.sensor.pointColorsEnabled"
    private static let sensorCameraImageEnabledDefaultsKey = "com.roamr.wasm.sensor.cameraImageEnabled"
    private static let recordingEnabledDefaultsKey = "com.roamr.wasm.recordingEnabled"
    private static let recordingPathDefaultsKey = "com.roamr.wasm.recordingPath"
    private static let recordingFolderBookmarkDefaultsKey = "com.roamr.wasm.recordingFolderBookmark"
    private static let recordingGuestDirectory = "/data"
    private static let defaultRecordingPath = "WasmRecordings"
    private static let sensorImuEnabledEnvKey = "ROAMR_SENSOR_ENABLE_IMU"
    private static let sensorWheelOdometryEnabledEnvKey = "ROAMR_SENSOR_ENABLE_WHEEL_ODOMETRY"
    private static let sensorLidarPointsEnabledEnvKey = "ROAMR_SENSOR_ENABLE_LIDAR_POINTS"
    private static let sensorPointColorsEnabledEnvKey = "ROAMR_SENSOR_ENABLE_POINT_COLORS"
    private static let sensorCameraImageEnabledEnvKey = "ROAMR_SENSOR_ENABLE_CAMERA_IMAGE"
    private static let recordingEnabledEnvKey = "ROAMR_RECORDING_ENABLED"
    private static let recordingDirectoryEnvKey = "ROAMR_RECORDING_DIR"

    private var isInitialized = false
    private var globalNativeSymbolPtr: UnsafeMutablePointer<NativeSymbol>?
    private var globalModuleNamePtr: UnsafeMutablePointer<CChar>?

    private var currentModuleInstance: OpaquePointer?
    private var currentRuntimeBundleURL: URL?
    private var shouldStop = false
    private var activeRecordingSecurityScopeURL: URL?
    private let lock = NSLock()
    @Published var isRunning = false
    @Published var currentRunDisplayName: String?
    @Published var logLines: [String] = []
    @Published var latestMapJPEGData: Data?
    @Published var latestMapTimestamp: Double = 0
    @Published var latestMapFrameCount: Int = 0
    @Published private(set) var sensorConfig: WasmSensorConfig
    @Published private(set) var recordingEnabled: Bool
    @Published private(set) var recordingPath: String
    @Published private(set) var selectedRecordingFolderPath: String?

    private init() {
        self.sensorConfig = WasmSensorConfig(
            imuEnabled: UserDefaults.standard.object(forKey: Self.sensorImuEnabledDefaultsKey) as? Bool ?? WasmSensorConfig.default.imuEnabled,
            wheelOdometryEnabled: UserDefaults.standard.object(forKey: Self.sensorWheelOdometryEnabledDefaultsKey) as? Bool ?? WasmSensorConfig.default.wheelOdometryEnabled,
            lidarPointsEnabled: UserDefaults.standard.object(forKey: Self.sensorLidarPointsEnabledDefaultsKey) as? Bool ?? WasmSensorConfig.default.lidarPointsEnabled,
            pointColorsEnabled: UserDefaults.standard.object(forKey: Self.sensorPointColorsEnabledDefaultsKey) as? Bool ?? WasmSensorConfig.default.pointColorsEnabled,
            cameraImageEnabled: UserDefaults.standard.object(forKey: Self.sensorCameraImageEnabledDefaultsKey) as? Bool ?? WasmSensorConfig.default.cameraImageEnabled
        )
        self.recordingEnabled =
            UserDefaults.standard.object(forKey: Self.recordingEnabledDefaultsKey) as? Bool ?? false
        let storedRecordingPath =
            UserDefaults.standard.string(forKey: Self.recordingPathDefaultsKey) ?? Self.defaultRecordingPath
        self.recordingPath = Self.normalizeRecordingPath(storedRecordingPath)
        self.selectedRecordingFolderPath = Self.resolveStoredRecordingFolderURL()?.path
    }

    func effectiveSensorConfig() -> WasmSensorConfig {
        var config = sensorConfig
        config.pointColorsEnabled = false
        return config
    }

    func setSensorConfig(_ updatedConfig: WasmSensorConfig) {
        UserDefaults.standard.set(updatedConfig.imuEnabled, forKey: Self.sensorImuEnabledDefaultsKey)
        UserDefaults.standard.set(updatedConfig.wheelOdometryEnabled, forKey: Self.sensorWheelOdometryEnabledDefaultsKey)
        UserDefaults.standard.set(updatedConfig.lidarPointsEnabled, forKey: Self.sensorLidarPointsEnabledDefaultsKey)
        UserDefaults.standard.set(updatedConfig.pointColorsEnabled, forKey: Self.sensorPointColorsEnabledDefaultsKey)
        UserDefaults.standard.set(updatedConfig.cameraImageEnabled, forKey: Self.sensorCameraImageEnabledDefaultsKey)
        DispatchQueue.main.async {
            self.sensorConfig = updatedConfig
        }
    }

    func startConfiguredHostSensors() {
        let config = effectiveSensorConfig()
        appendLogLine(
            "[host][sensors] imu=\(config.imuEnabled ? 1 : 0) wheel=\(config.wheelOdometryEnabled ? 1 : 0) points=\(config.lidarPointsEnabled ? 1 : 0) point_colors=\(config.pointColorsEnabled ? 1 : 0) rgb=\(config.cameraImageEnabled ? 1 : 0)"
        )
        if config.wheelOdometryEnabled {
            BluetoothManager.shared.prepareWheelOdometryForNewWasmRun()
        }
        if config.imuEnabled {
            IMUManager.shared.start()
        }
        if config.lidarPointsEnabled || config.cameraImageEnabled {
            AVManager.shared.start()
        }
    }

    func stopConfiguredHostSensors() {
        AVManager.shared.stop()
        IMUManager.shared.stop()
    }

    func setRecordingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.recordingEnabledDefaultsKey)
        DispatchQueue.main.async {
            self.recordingEnabled = enabled
        }
    }

    func setRecordingPath(_ path: String) {
        let normalizedPath = Self.normalizeRecordingPath(path)
        UserDefaults.standard.set(normalizedPath, forKey: Self.recordingPathDefaultsKey)
        DispatchQueue.main.async {
            self.recordingPath = normalizedPath
        }
    }

    func resetRecordingPath() {
        setRecordingPath(Self.defaultRecordingPath)
    }

    func defaultRecordingPath() -> String {
        Self.defaultRecordingPath
    }

    func setRecordingFolderURL(_ url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: Self.recordingFolderBookmarkDefaultsKey)
        let resolvedPath = Self.resolveRecordingFolderURL(from: bookmarkData)?.path ?? url.path
        DispatchQueue.main.async {
            self.selectedRecordingFolderPath = resolvedPath
        }
    }

    func clearRecordingFolderSelection() {
        releaseRecordingSecurityScope()
        UserDefaults.standard.removeObject(forKey: Self.recordingFolderBookmarkDefaultsKey)
        DispatchQueue.main.async {
            self.selectedRecordingFolderPath = nil
        }
    }

    func recordingGuestDirectoryPath() -> String {
        Self.recordingGuestDirectory
    }

    func recordingsDirectoryURL() -> URL? {
        if let selectedFolderURL = Self.resolveStoredRecordingFolderURL() {
            return selectedFolderURL
        }
        let normalizedPath = Self.normalizeRecordingPath(recordingPath)
        let fileManager = FileManager.default
        if normalizedPath.hasPrefix("/") {
            return URL(fileURLWithPath: normalizedPath, isDirectory: true)
        }
        guard let baseDirectory = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return baseDirectory.appendingPathComponent(normalizedPath, isDirectory: true)
    }

    func stop() {
        lock.lock()
        shouldStop = true
        if let moduleInstance = currentModuleInstance {
            wasm_runtime_terminate(moduleInstance)
        }
        lock.unlock()
        appendLogLine("WASM stop requested")
    }

    func initializeRuntime() -> Bool {
        if isInitialized { return true }

        guard wasm_runtime_init() else {
            appendLogLine("Fatal Error: WAMR runtime initialization failed.")
            return false
        }
        wasm_runtime_set_max_thread_num(Self.maxWasmThreads)
        appendLogLine("Configured WAMR max thread count: \(Self.maxWasmThreads)")

        // Prepare Native Symbols
        struct NativeFunction {
            let name: String
            let signature: String
            let impl: CFunction
        }

        let nativeFunctions: [NativeFunction] = [
            NativeFunction(name: "read_imu", signature: "(*)", impl: read_imu_impl),
            NativeFunction(name: "read_wheel_odometry", signature: "(*)", impl: read_wheel_odometry_impl),
            NativeFunction(name: "init_camera", signature: "(*)", impl: init_camera_impl),
            NativeFunction(name: "read_lidar_camera", signature: "(*)", impl: read_lidar_camera_impl),
            NativeFunction(name: "ml_open_model", signature: "(*)", impl: ml_open_model_impl),
            NativeFunction(name: "ml_run_latest_camera_frame", signature: "(*)", impl: ml_run_latest_camera_frame_impl),
            NativeFunction(name: "ml_close_model", signature: "(*)", impl: ml_close_model_impl),
            NativeFunction(name: "wasm_log_text", signature: "(*)", impl: wasm_log_text_impl),
            NativeFunction(name: "rerun_log_lidar_frame", signature: "(*)", impl: rerun_log_lidar_frame_impl),
            NativeFunction(name: "rerun_log_map_frame", signature: "(*)", impl: rerun_log_map_frame_impl),
            NativeFunction(name: "rerun_log_imu", signature: "(*)", impl: rerun_log_imu_impl),
            NativeFunction(name: "rerun_log_pose", signature: "(*)", impl: rerun_log_pose_impl),
            NativeFunction(name: "rerun_log_pose_wheel", signature: "(*)", impl: rerun_log_pose_wheel_impl),
            NativeFunction(name: "write_motors", signature: "(*)", impl: write_motors_impl)
        ]

        let nativeSymbolPtr = UnsafeMutablePointer<NativeSymbol>.allocate(capacity: nativeFunctions.count)

        var symbolPtrs: [UnsafeMutablePointer<CChar>] = []

        for (index, function) in nativeFunctions.enumerated() {
            let namePtr = function.name.withCString { strdup($0) }
            let sigPtr = function.signature.withCString { strdup($0) }

            if let namePtr = namePtr, let sigPtr = sigPtr {
                symbolPtrs.append(namePtr)
                symbolPtrs.append(sigPtr)

                let funcPtr = unsafeBitCast(function.impl, to: UnsafeMutableRawPointer.self)

                nativeSymbolPtr[index] = NativeSymbol(
                    symbol: UnsafePointer(namePtr),
                    func_ptr: funcPtr,
                    signature: UnsafePointer(sigPtr),
                    attachment: nil
                )
            }
        }

        let moduleName = "host"
        let moduleNamePtr = moduleName.withCString { strdup($0) }

        globalNativeSymbolPtr = nativeSymbolPtr
        globalModuleNamePtr = UnsafeMutablePointer(mutating: moduleNamePtr)

        guard wasm_runtime_register_natives(moduleNamePtr, nativeSymbolPtr, UInt32(nativeFunctions.count)) else {
            appendLogLine("Error: Failed to register native symbols")
            return false
        }

        isInitialized = true
        return true
    }

    func runWasmFile(named fileName: String) {
        guard initializeRuntime() else { return }

        let bundle = Bundle.main
        var wasmURL: URL?

        if let url = bundle.url(forResource: fileName, withExtension: "wasm") {
            wasmURL = url
        } else if let url = bundle.url(forResource: fileName, withExtension: "wasm", subdirectory: "WASM") {
            wasmURL = url
        } else if let resourceURL = bundle.resourceURL {
            // Fallback for folder references packaged as subdirectories
            let candidate = resourceURL.appendingPathComponent("WASM/\(fileName).wasm")
            if FileManager.default.fileExists(atPath: candidate.path) {
                wasmURL = candidate
            }
        }

        guard let resolvedWasmURL = wasmURL else {
            let present = bundle.paths(forResourcesOfType: "wasm", inDirectory: nil)
            appendLogLine("Error: Could not find \(fileName).wasm. Bundle currently has: \(present)")
            return
        }
        runWasmFile(at: resolvedWasmURL)
    }

    func runWasmFile(at fileURL: URL) {
        guard initializeRuntime() else { return }

        lock.lock()
        shouldStop = false
        currentRuntimeBundleURL = fileURL.deletingLastPathComponent()
        lock.unlock()
        ModelRunner.shared.beginRun(bundleBaseURL: fileURL.deletingLastPathComponent())
        clearLogs()
        clearMapPreview()
        clearMlDetections()
        appendLogLine("Running \(fileURL.lastPathComponent)")
        updateRunningState(true, currentRunDisplayName: fileURL.lastPathComponent)

        do {
            let wasmBytes = try Data(contentsOf: fileURL)

            wasmBytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                defer {
                    releaseRecordingSecurityScope()
                    ModelRunner.shared.endRun()
                    WebSocketManager.shared.publishMlDetectionsReset()
                    lock.lock()
                    currentRuntimeBundleURL = nil
                    lock.unlock()
                    updateRunningState(false, currentRunDisplayName: nil)
                }

                guard let baseAddress = buffer.baseAddress else { return }
                let wasmBuffer = UnsafeMutablePointer(mutating: baseAddress.assumingMemoryBound(to: UInt8.self))
                let wasmBufferSize = UInt32(buffer.count)

                var errorBuf = [CChar](repeating: 0, count: 128)

                // Load module
                guard let wasmModule = wasm_runtime_load(wasmBuffer, wasmBufferSize, &errorBuf, UInt32(errorBuf.count)) else {
                    let message = "Error loading WASM module: \(String(cString: errorBuf))"
                    appendLogLine(message)
                    return
                }

                // Instantiate module
                let stackSize: UInt32 = 65536  // 64KB for threading
                let heapSize: UInt32 = 65536   // 64KB for threading
                let wasiOptions = prepareWASIRuntimeOptions()

                guard let moduleInstance = instantiateModule(
                    wasmModule,
                    stackSize: stackSize,
                    heapSize: heapSize,
                    errorBuffer: &errorBuf,
                    wasiOptions: wasiOptions
                ) else {
                    let message = "Error instantiating WASM module: \(String(cString: errorBuf))"
                    appendLogLine(message)
                    wasm_runtime_unload(wasmModule)
                    return
                }

                // Store module instance for potential termination
                lock.lock()
                currentModuleInstance = moduleInstance
                lock.unlock()

                // Create execution environment
                guard let execEnv = wasm_runtime_create_exec_env(moduleInstance, stackSize) else {
                    let message = "Error creating execution environment"
                    appendLogLine(message)
                    lock.lock()
                    currentModuleInstance = nil
                    lock.unlock()
                    wasm_runtime_deinstantiate(moduleInstance)
                    wasm_runtime_unload(wasmModule)
                    return
                }

                // Call _start function (default entry point for WASI)
                if let startFunc = wasm_runtime_lookup_function(moduleInstance, "_start") {
                     if !wasm_runtime_call_wasm(execEnv, startFunc, 0, nil) {
                         let wasStopped = shouldStop
                         if wasStopped {
                             appendLogLine("WASM execution was stopped")
                         } else {
                             let exception = String(cString: wasm_runtime_get_exception(moduleInstance))
                             appendLogLine("Error calling _start: \(exception)")
                         }
                     }
                } else {
                    appendLogLine("Error: Could not find _start function")
                }

                // Clear module instance reference
                lock.lock()
                currentModuleInstance = nil
                lock.unlock()

                // Cleanup instance-specific resources
                wasm_runtime_destroy_exec_env(execEnv)
                wasm_runtime_deinstantiate(moduleInstance)
                wasm_runtime_unload(wasmModule)

                appendLogLine("WASM execution finished.")
            }
        } catch {
            releaseRecordingSecurityScope()
            ModelRunner.shared.endRun()
            WebSocketManager.shared.publishMlDetectionsReset()
            lock.lock()
            currentRuntimeBundleURL = nil
            lock.unlock()
            appendLogLine("Error reading WASM file: \(error.localizedDescription)")
            updateRunningState(false, currentRunDisplayName: nil)
        }
    }

    func runtimeAssetURL(for path: String) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        if trimmedPath.hasPrefix("/") {
            return URL(fileURLWithPath: trimmedPath, isDirectory: false)
        }

        lock.lock()
        let bundleURL = currentRuntimeBundleURL
        lock.unlock()
        return bundleURL?.appendingPathComponent(trimmedPath, isDirectory: false)
    }

    private func updateRunningState(_ isRunning: Bool, currentRunDisplayName: String?) {
        DispatchQueue.main.async {
            self.isRunning = isRunning
            self.currentRunDisplayName = currentRunDisplayName
            WebSocketManager.shared.publishWasmControlState()
        }
    }

    func clearLogs() {
        WebSocketManager.shared.publishWasmConsoleReset()
        DispatchQueue.main.async {
            self.logLines.removeAll()
        }
    }

    func clearMapPreview() {
        WebSocketManager.shared.publishMapFrameReset()
        DispatchQueue.main.async {
            self.latestMapJPEGData = nil
            self.latestMapTimestamp = 0
            self.latestMapFrameCount = 0
        }
    }

    func clearMlDetections() {
        WebSocketManager.shared.publishMlDetectionsReset()
    }

    func appendLogLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        WebSocketManager.shared.publishWasmConsoleLine(trimmed)
        DispatchQueue.main.async {
            self.logLines.append(trimmed)
            if self.logLines.count > Self.maxLogLines {
                self.logLines.removeFirst(self.logLines.count - Self.maxLogLines)
            }
        }
    }

    func updateMapPreview(jpegData: Data, timestamp: Double) {
        guard !jpegData.isEmpty else { return }
        DispatchQueue.main.async {
            self.latestMapJPEGData = jpegData
            self.latestMapTimestamp = timestamp
            self.latestMapFrameCount += 1
        }
    }

    private struct WASIRuntimeOptions {
        let env: [String]
        let preopenedHostDirectories: [String]
        let mappedDirectories: [String]
    }

    private func prepareWASIRuntimeOptions() -> WASIRuntimeOptions {
        let sensorConfig = effectiveSensorConfig()
        var env = [
            "\(Self.sensorImuEnabledEnvKey)=\(sensorConfig.imuEnabled ? 1 : 0)",
            "\(Self.sensorWheelOdometryEnabledEnvKey)=\(sensorConfig.wheelOdometryEnabled ? 1 : 0)",
            "\(Self.sensorLidarPointsEnabledEnvKey)=\(sensorConfig.lidarPointsEnabled ? 1 : 0)",
            "\(Self.sensorPointColorsEnabledEnvKey)=\(sensorConfig.pointColorsEnabled ? 1 : 0)",
            "\(Self.sensorCameraImageEnabledEnvKey)=\(sensorConfig.cameraImageEnabled ? 1 : 0)",
            "\(Self.recordingEnabledEnvKey)=0",
            "\(Self.recordingDirectoryEnvKey)=\(Self.recordingGuestDirectory)"
        ]

        guard recordingEnabled else {
            return WASIRuntimeOptions(
                env: env,
                preopenedHostDirectories: [],
                mappedDirectories: []
            )
        }

        do {
            let directoryURL = try ensureRecordingsDirectory()
            env[5] = "\(Self.recordingEnabledEnvKey)=1"
            return WASIRuntimeOptions(
                env: env,
                preopenedHostDirectories: [directoryURL.path],
                mappedDirectories: ["\(Self.recordingGuestDirectory)::\(directoryURL.path)"]
            )
        } catch {
            appendLogLine("Recording disabled for this run: \(error.localizedDescription)")
            return WASIRuntimeOptions(
                env: env,
                preopenedHostDirectories: [],
                mappedDirectories: []
            )
        }
    }

    private func ensureRecordingsDirectory() throws -> URL {
        releaseRecordingSecurityScope()
        guard let directoryURL = runtimeRecordingDirectoryURL() else {
            throw NSError(
                domain: "WasmManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Application Support directory is unavailable"]
            )
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directoryURL
    }

    private static func normalizeRecordingPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? defaultRecordingPath : trimmedPath
    }

    private func runtimeRecordingDirectoryURL() -> URL? {
        if let selectedFolderURL = Self.resolveStoredRecordingFolderURL() {
            guard selectedFolderURL.startAccessingSecurityScopedResource() else {
                appendLogLine("Recording folder access denied; falling back to app-local path")
                return fallbackRecordingDirectoryURL()
            }
            activeRecordingSecurityScopeURL = selectedFolderURL
            return selectedFolderURL
        }
        return fallbackRecordingDirectoryURL()
    }

    private func fallbackRecordingDirectoryURL() -> URL? {
        let normalizedPath = Self.normalizeRecordingPath(recordingPath)
        let fileManager = FileManager.default
        if normalizedPath.hasPrefix("/") {
            return URL(fileURLWithPath: normalizedPath, isDirectory: true)
        }
        guard let baseDirectory = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return baseDirectory.appendingPathComponent(normalizedPath, isDirectory: true)
    }

    private func releaseRecordingSecurityScope() {
        guard let url = activeRecordingSecurityScopeURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeRecordingSecurityScopeURL = nil
    }

    private static func resolveStoredRecordingFolderURL() -> URL? {
        guard let bookmarkData =
            UserDefaults.standard.data(forKey: recordingFolderBookmarkDefaultsKey) else {
            return nil
        }
        return resolveRecordingFolderURL(from: bookmarkData)
    }

    private static func resolveRecordingFolderURL(from bookmarkData: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func instantiateModule(
        _ wasmModule: OpaquePointer,
        stackSize: UInt32,
        heapSize: UInt32,
        errorBuffer: inout [CChar],
        wasiOptions: WASIRuntimeOptions
    ) -> OpaquePointer? {
        return withOwnedCStringArray(wasiOptions.preopenedHostDirectories) { directoryPointers in
            let directoryCount = UInt32(directoryPointers.count)
            return directoryPointers.withUnsafeBufferPointer { directoryBuffer in
                let directoryBase = directoryBuffer.baseAddress.map { UnsafeMutablePointer(mutating: $0) }
                return withOwnedCStringArray(wasiOptions.mappedDirectories) { mappedDirectoryPointers in
                    let mappedDirectoryCount = UInt32(mappedDirectoryPointers.count)
                    return mappedDirectoryPointers.withUnsafeBufferPointer { mappedDirectoryBuffer in
                        let mappedDirectoryBase =
                            mappedDirectoryBuffer.baseAddress.map { UnsafeMutablePointer(mutating: $0) }
                        return withOwnedCStringArray(wasiOptions.env) { envPointers in
                            let envCount = UInt32(envPointers.count)
                            return envPointers.withUnsafeBufferPointer { envBuffer in
                                let envBase = envBuffer.baseAddress.map { UnsafeMutablePointer(mutating: $0) }
                                wasm_runtime_set_wasi_args(
                                    wasmModule,
                                    directoryBase,
                                    directoryCount,
                                    mappedDirectoryBase,
                                    mappedDirectoryCount,
                                    envBase,
                                    envCount,
                                    nil,
                                    0
                                )
                                return wasm_runtime_instantiate(
                                    wasmModule,
                                    stackSize,
                                    heapSize,
                                    &errorBuffer,
                                    UInt32(errorBuffer.count)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private func withOwnedCStringArray<R>(
    _ strings: [String],
    body: ([UnsafePointer<CChar>?]) -> R
) -> R {
    let ownedPointers = strings.map { strdup($0) }
    defer {
        ownedPointers.forEach { free($0) }
    }
    return body(
        ownedPointers.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
    )
}

func wasm_log_text_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
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
        if baseAddress + UInt(wasmTextLogPayloadSize) > endAddress {
            return
        }
    }

    let requestedLength = ptr.assumingMemoryBound(to: UInt32.self).pointee
    let clampedLength = min(Int(requestedLength), wasmTextLogMaxBytes)
    let textBytes = ptr.advanced(by: MemoryLayout<UInt32>.size)
        .assumingMemoryBound(to: UInt8.self)
    let buffer = UnsafeBufferPointer(start: textBytes, count: clampedLength)
    let text = String(decoding: buffer, as: UTF8.self)

    WasmManager.shared.appendLogLine(text)
}
