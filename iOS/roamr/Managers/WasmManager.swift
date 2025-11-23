import Foundation

class WasmManager {
    static let shared = WasmManager()
    
    private var isInitialized = false
    private var globalNativeSymbolPtr: UnsafeMutablePointer<NativeSymbol>?
    private var globalModuleNamePtr: UnsafeMutablePointer<CChar>?
    
    private init() {}
    
    func initializeRuntime() -> Bool {
        if isInitialized { return true }
        
        print("Initializing WAMR runtime...")
        guard wasm_runtime_init() else {
            print("Fatal Error: WAMR runtime initialization failed.")
            return false
        }
        
        // Prepare Native Symbols
        let symbolName = "read_imu"
        let signature = "(*)" // pointer argument
        
        let symbolPtr = symbolName.withCString { strdup($0) }
        let signaturePtr = signature.withCString { strdup($0) }
        
        // Get the C function pointer properly
        typealias CFunction = @convention(c) (wasm_exec_env_t?, UnsafeMutableRawPointer?) -> Void
        let cFunction: CFunction = read_imu_impl
        let funcPtr = unsafeBitCast(cFunction as CFunction, to: UnsafeMutableRawPointer.self)
        
        // Allocate NativeSymbol array on the heap to ensure it persists
        let nativeSymbolPtr = UnsafeMutablePointer<NativeSymbol>.allocate(capacity: 1)
        nativeSymbolPtr.initialize(to: NativeSymbol(
            symbol: UnsafePointer(symbolPtr),
            func_ptr: funcPtr,
            signature: UnsafePointer(signaturePtr),
            attachment: nil
        ))
        
        let moduleName = "host"
        let moduleNamePtr = moduleName.withCString { strdup($0) }
        
        // Save globals to prevent leak/GC issues
        globalNativeSymbolPtr = nativeSymbolPtr
        globalModuleNamePtr = UnsafeMutablePointer(mutating: moduleNamePtr)
        
        // Register Natives
        guard wasm_runtime_register_natives(moduleNamePtr, nativeSymbolPtr, 1) else {
            print("Error: Failed to register native symbols")
            return false
        }
        
        isInitialized = true
        return true
    }
    
    func runWasmFile(named fileName: String) {
        guard initializeRuntime() else { return }
        
        guard let wasmPath = Bundle.main.path(forResource: fileName, ofType: "wasm") else {
            print("Error: Could not find \(fileName).wasm")
            return
        }
        
        do {
            let wasmBytes = try Data(contentsOf: URL(fileURLWithPath: wasmPath))
            
            wasmBytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let baseAddress = buffer.baseAddress else { return }
                let wasmBuffer = UnsafeMutablePointer(mutating: baseAddress.assumingMemoryBound(to: UInt8.self))
                let wasmBufferSize = UInt32(buffer.count)
                
                var errorBuf = [CChar](repeating: 0, count: 128)
                
                // Load module
                guard let wasmModule = wasm_runtime_load(wasmBuffer, wasmBufferSize, &errorBuf, UInt32(errorBuf.count)) else {
                    print("Error loading WASM module: \(String(cString: errorBuf))")
                    return
                }
                
                // Instantiate module
                let stackSize: UInt32 = 65536  // 64KB for threading
                let heapSize: UInt32 = 65536   // 64KB for threading
                
                guard let moduleInstance = wasm_runtime_instantiate(wasmModule, stackSize, heapSize, &errorBuf, UInt32(errorBuf.count)) else {
                    print("Error instantiating WASM module: \(String(cString: errorBuf))")
                    wasm_runtime_unload(wasmModule)
                    return
                }
                
                // Create execution environment
                guard let execEnv = wasm_runtime_create_exec_env(moduleInstance, stackSize) else {
                    print("Error creating execution environment")
                    wasm_runtime_deinstantiate(moduleInstance)
                    wasm_runtime_unload(wasmModule)
                    return
                }
                
                print("Running WASM module...")
                
                // Call _start function (default entry point for WASI)
                // Note: wasm_application_execute_main is often used for WASI modules
                // but if we just want to run the main function we can use this or lookup "_start"
                
                // For this specific test, we can use wasm_application_execute_main if the module is built as a command
                // Or lookup "_start" manually.
                // The previous code used wasm_application_execute_main logic implicitly or explicitly?
                // Previous code:
                /*
                 let func_inst = wasm_runtime_lookup_function(moduleInstance, "_start", nil)
                 if func_inst != nil {
                     wasm_runtime_call_wasm(execEnv, func_inst, 0, nil)
                 }
                 */
                
                // Let's stick to looking up _start for now as it's standard for WASI commands
                if let startFunc = wasm_runtime_lookup_function(moduleInstance, "_start") {
                     if !wasm_runtime_call_wasm(execEnv, startFunc, 0, nil) {
                         print("Error calling _start: \(String(cString: wasm_runtime_get_exception(moduleInstance)))")
                     }
                } else {
                    print("Error: Could not find _start function")
                }
                
                // Cleanup instance-specific resources
                wasm_runtime_destroy_exec_env(execEnv)
                wasm_runtime_deinstantiate(moduleInstance)
                wasm_runtime_unload(wasmModule)
                
                print("WASM execution finished.")
            }
        } catch {
            print("Error reading WASM file: \(error)")
        }
    }
}
