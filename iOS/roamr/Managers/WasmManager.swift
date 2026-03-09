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

final class WasmManager: ObservableObject {
    static let shared = WasmManager()
    private static let maxWasmThreads: UInt32 = 8
    private static let maxLogLines = 200

    private var isInitialized = false
    private var globalNativeSymbolPtr: UnsafeMutablePointer<NativeSymbol>?
    private var globalModuleNamePtr: UnsafeMutablePointer<CChar>?

    private var currentModuleInstance: OpaquePointer?
    private var shouldStop = false
    private let lock = NSLock()
    @Published var isRunning = false
    @Published var logLines: [String] = []
    @Published var latestMapJPEGData: Data?
    @Published var latestMapTimestamp: Double = 0
    @Published var latestMapFrameCount: Int = 0

    private init() {}

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
        lock.unlock()
        clearLogs()
        clearMapPreview()
        appendLogLine("Running \(fileURL.lastPathComponent)")
        DispatchQueue.main.async {
            self.isRunning = true
        }

        do {
            let wasmBytes = try Data(contentsOf: fileURL)

            wasmBytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let baseAddress = buffer.baseAddress else { return }
                let wasmBuffer = UnsafeMutablePointer(mutating: baseAddress.assumingMemoryBound(to: UInt8.self))
                let wasmBufferSize = UInt32(buffer.count)

                var errorBuf = [CChar](repeating: 0, count: 128)

                // Load module
                guard let wasmModule = wasm_runtime_load(wasmBuffer, wasmBufferSize, &errorBuf, UInt32(errorBuf.count)) else {
                    let message = "Error loading WASM module: \(String(cString: errorBuf))"
                    appendLogLine(message)
                    DispatchQueue.main.async {
                        self.isRunning = false
                    }
                    return
                }

                // Instantiate module
                let stackSize: UInt32 = 65536  // 64KB for threading
                let heapSize: UInt32 = 65536   // 64KB for threading

                guard let moduleInstance = wasm_runtime_instantiate(wasmModule, stackSize, heapSize, &errorBuf, UInt32(errorBuf.count)) else {
                    let message = "Error instantiating WASM module: \(String(cString: errorBuf))"
                    appendLogLine(message)
                    DispatchQueue.main.async {
                        self.isRunning = false
                    }
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
                    DispatchQueue.main.async {
                        self.isRunning = false
                    }
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
                DispatchQueue.main.async {
                    self.isRunning = false
                }
            }
        } catch {
            appendLogLine("Error reading WASM file: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async {
            self.logLines.removeAll()
        }
    }

    func clearMapPreview() {
        DispatchQueue.main.async {
            self.latestMapJPEGData = nil
            self.latestMapTimestamp = 0
            self.latestMapFrameCount = 0
        }
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
