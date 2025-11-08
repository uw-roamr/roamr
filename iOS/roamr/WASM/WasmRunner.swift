//
//  WasmRunner.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import Foundation

final class WasmRunner {
	
	// --- Use the correct C types ---
	private var env: IM3Environment?
	private var runtime: IM3Runtime?
	private var module: IM3Module?
	
	// Keep the file data in memory so the pointer is stable
	private var wasmFileData: Data?

	init?(wasmPath: String) {
		
		// 1. Create Environment
		self.env = m3_NewEnvironment()
		guard self.env != nil else {
			print("Error: m3_NewEnvironment failed")
			return nil
		}
		
		// 2. Create Runtime
		let stackSize: UInt32 = 64 * 1024 // 64k
		self.runtime = m3_NewRuntime(self.env, stackSize, nil)
		guard self.runtime != nil else {
			print("Error: m3_NewRuntime failed")
			m3_FreeEnvironment(self.env) // Clean up
			return nil
		}
		
		// 3. Load WASM file
		guard let data = try? Data(contentsOf: URL(fileURLWithPath: wasmPath)), !data.isEmpty else {
			print("Error: Failed to load wasm file from path: \(wasmPath)")
			self.cleanup()
			return nil
		}
		self.wasmFileData = data // Keep data alive
		
		// 4. Parse Module
		var modPtr: IM3Module? = nil
		let parseResult = self.wasmFileData!.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> M3Result? in
			// baseAddress is guaranteed to be non-nil since data is not empty
			let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
			return m3_ParseModule(self.env, &modPtr, base, UInt32(data.count))
		}
		
		if parseResult != nil {
			print("Error: m3_ParseModule failed: \(String(cString: parseResult!))")
			self.cleanup()
			return nil
		}
		
		self.module = modPtr
		
		// 5. Load Module into Runtime
		let loadErr = m3_LoadModule(self.runtime, self.module)
		if loadErr != nil {
			print("Error: m3_LoadModule failed: \(String(cString: loadErr!))")
			self.cleanup()
			return nil
		}
		
		// NOTE: We do NOT link any host functions or write to memory.
	}
	
	deinit {
		self.cleanup()
	}
	
	/// Cleans up all Wasm3 resources
	private func cleanup() {
		if let r = self.runtime { m3_FreeRuntime(r) }
		if let e = self.env { m3_FreeEnvironment(e) }
	}
	
	/// Calls a WASM function with NO arguments and returns an Int32
	func callFunctionWithoutArgs(_ name: String) -> Int32? {
		
		// 1. Find the function
		var fn: IM3Function? = nil
		let findErr = m3_FindFunction(&fn, self.runtime, name)
		
		if findErr != nil || fn == nil {
			print("Error: m3_FindFunction failed for '\(name)'")
			return nil
		}
		
		// 2. Call the function with 0 arguments
		let callErr = m3_Call(fn, 0, nil)
		
		if callErr != nil {
			print("Error: m3_Call failed: \(String(cString: callErr!))")
			return nil
		}
		
		// 3. Get the Int32 result
		var resultPtr: UnsafeRawPointer? = nil
		let getResultErr = m3_GetResults(fn, 0, &resultPtr)

		if getResultErr != nil {
			print("Error: m3_GetResults failed: \(String(cString: getResultErr!))")
			return nil
		}
		
		guard let resultPtr = resultPtr else {
			print("Error: m3_GetResults returned a nil result pointer.")
			return nil
		}
		
		// Read the Int32 value from the result pointer
		let resultValue = resultPtr.assumingMemoryBound(to: Int32.self).pointee
		
		return resultValue
	}
}
