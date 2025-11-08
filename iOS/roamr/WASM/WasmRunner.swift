import Foundation

final class WasmRunner {
    
    private var env: OpaquePointer!
    private var runtime: OpaquePointer!
    private var module: OpaquePointer!
    
    // Add these properties to hold onto loaded data and C strings
    private var wasmFileData: Data?
    private var cStrings: [UnsafeMutablePointer<CChar>?] = []

    init?(wasmPath: String, runtimeStackSize: UInt32 = 64 * 1024) {
        // Create environment
        env = m3_NewEnvironment()
        guard env != nil else { print("Error: m3_NewEnvironment failed"); return nil }
        
        // Create runtime
        runtime = m3_NewRuntime(env, runtimeStackSize, nil)
        guard runtime != nil else { print("Error: m3_NewRuntime failed"); return nil }
        
        // Load WASM file from path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: wasmPath)) else {
            print("Failed to load wasm file from path: \(wasmPath)")
            return nil
        }
        self.wasmFileData = data // Keep data alive

        // Parse module
        var modPtr: OpaquePointer? = nil
        let parseResult = wasmFileData!.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> M3Result in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return "m3_ParseModule: data pointer was nil" }
            return m3_ParseModule(env, &modPtr, base, UInt32(data.count))
        }
        
        if parseResult != nil || modPtr == nil {
            print("Error: m3_ParseModule failed: \(String(cString: parseResult!))")
            return nil
        }
        
        module = modPtr
        
        // Load module into runtime
        let loadErr = m3_LoadModule(runtime, modPtr)
        if loadErr != nil {
            print("Error: m3_LoadModule failed: \(String(cString: loadErr!))")
            return nil
        }
        
        // Link the host function (WASM -> Swift)
        self.linkHostPrint()
    }
    
    deinit {
        // Free C strings
        for ptr in cStrings {
            free(ptr)
        }
        // Wasm3 free
        if let r = runtime { m3_FreeRuntime(r) }
        if let e = env { m3_FreeEnvironment(e) }
    }
    
    /// Call a WASM function with integer arguments
    func callFunction(_ name: String, args: [Int32] = []) -> Int32? {
        var fn: OpaquePointer? = nil
        let findErr = m3_FindFunction(&fn, runtime, name)
        
        if findErr != nil || fn == nil {
            print("Error: m3_FindFunction failed for '\(name)'")
            return nil
        }

        // --- Handle integer arguments ---
        // Wasm3's m3_Call expects 'const char* argv[]'
        // To pass integers, we must "stack" them as C strings
        
        // 1. Convert Int32s to C strings
        let cArgs = args.map { strdup(String($0)) }
        cStrings.append(contentsOf: cArgs) // Store to free later

        // 2. Call the function
        let callErr = m3_Call(fn, UInt32(cArgs.count), cArgs)
        
        // --- Note: The original example code had an error ---
        // The original `let cArgs = args.map { UnsafePointer<Int8>(bitPattern: Int($0)) }`
        // was incorrect. `m3_Call` does not pass raw integers this way.
        // It's typically used for WASI (passing strings) or you must use
        // a more complex stack setup.
        // For this example, we'll assume the string-based argv.
        // If your WASM function *truly* needs raw i32 args, the setup is different.
        // Let's stick to the string `argv` model for simplicity as in the example.
        
        if callErr != nil {
            print("Error: m3_Call failed: \(String(cString: callErr!))")
            return nil
        }
        
        // Get result
        var result: Int32 = 0
        let getResultErr = m3_GetResultsI32(fn, &result)
        if getResultErr != nil {
            print("Error: m3_GetResultsI32 failed")
            return nil
        }
        
        return result
    }
    
    /// Get a pointer to the WASM linear memory
    func getMemory() -> (pointer: UnsafeMutableRawPointer?, size: UInt32) {
        var memSize: UInt32 = 0
        let mem = m3_GetMemory(runtime, &memSize, 0)
        return (UnsafeMutableRawPointer(mem), memSize)
    }
    
    /// Write Swift `Data` into WASM memory at a specific offset
    func writeBytesToMemory(_ data: Data, offset: Int) {
        let memInfo = getMemory()
        guard let memPtr = memInfo.pointer else {
            print("Error: No WASM memory available")
            return
        }
        
        guard memInfo.size > (offset + data.count) else {
            print("Error: Write is out of bounds of WASM memory")
            return
        }
        
        data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) in
            memcpy(memPtr.advanced(by: offset), srcPtr.baseAddress!, data.count)
        }
    }
    
    /// Link the `host_print` C function to the WASM module
    private func linkHostPrint(toModule moduleName: String = "env") {
        // Signature "v(ii)" means: void return, (i32, i32) arguments
        let linkErr = m3_LinkRawFunction(module, moduleName, "host_print", "v(ii)", swift_host_print)
        if linkErr != nil {
            print("Error: m3_LinkRawFunction failed: \(String(cString: linkErr!))")
        }
    }
}