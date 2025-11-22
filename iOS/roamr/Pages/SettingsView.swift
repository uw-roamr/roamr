//
//  SettingsPage.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import Foundation
import SwiftUI

struct SettingsPage: View {
	@EnvironmentObject var lidarManager: LiDARManager

	private var appVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
	}

	var body: some View {
		VStack(spacing: 30) {
			Spacer()
			// App name
			Text("roamr")
				.font(.largeTitle)
				.fontWeight(.bold)

			// App version
			Text("Version \(appVersion)")
				.font(.subheadline)
				.foregroundColor(.secondary)

			// Description
			Text("Really Open-Source Autonomous Robot")
				.font(.caption)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 30)

			Button("Test WASM") {
//				try? self.test()
				runTest(operand1: Int32(6), operand2: Int32(7))
			}
			.padding()
			.background(Color.AppColor.accent.color)
			.foregroundColor(.white)
			.cornerRadius(20)

			Spacer()
		}
		.padding()
	}

	let defaultStackSize: UInt32 = 512 * 1024       // 512 KB
	let heapSize: UInt32 = 16 * 1024 * 1024         // 16 MB

	func runTest(operand1: Int32, operand2: Int32) {
		var wasmModule: wasm_module_t?
		var moduleInstance: wasm_module_inst_t?
		var execEnv: wasm_exec_env_t?

		// 1. Initialize the WAMR Runtime
		print("Initializing WAMR runtime...")

		guard wasm_runtime_init() else {
			print("Fatal Error: WAMR runtime initialization failed.")
			return
		}

		// Defer block ensures cleanup runs when the function exits.
		defer {
			if let env = execEnv {
				wasm_runtime_destroy_exec_env(env)
			}
			if let inst = moduleInstance {
				wasm_runtime_deinstantiate(inst)
			}
			if let mod = wasmModule {
				wasm_runtime_unload(mod)
			}
			wasm_runtime_destroy()
			print("WAMR runtime destroyed.")
		}

		// 2. Read WASM file
		guard let wasmURL = Bundle.main.url(forResource: "slam_main", withExtension: "wasm") else {
			print("Error: main.wasm file not found in bundle.")
			return
		}

		do {
			var wasmFileBuffer = try Data(contentsOf: wasmURL)

			var errorBuffer = [CChar](repeating: 0, count: 128)
			let wasmFileSize = UInt32(wasmFileBuffer.count)

			wasmFileBuffer.withUnsafeMutableBytes { wasmFilePtr in
				guard let wasmFileCArray = wasmFilePtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

				// 3. Load the WASM module
				print("Loading module")
				wasmModule = wasm_runtime_load(wasmFileCArray, wasmFileSize, &errorBuffer, UInt32(errorBuffer.count))

				guard let module = wasmModule else {
					let errorMsg = String(cString: errorBuffer)
					print("Error: WAMR failed to load module: \(errorMsg)")
					return
				}

				var instArgs = InstantiationArgs()
				instArgs.default_stack_size = UInt32(64 * 1024)        // 64 KB stack
				instArgs.host_managed_heap_size = UInt32(2 * 1024 * 1024) // 2 MB host-managed heap (bytes)
				instArgs.max_memory_pages = UInt32(256) // 256 pages * 64KiB/page = 16 MB max

				guard let instance = wasm_runtime_instantiate_ex(module, &instArgs, &errorBuffer, UInt32(errorBuffer.count)) else {
					let msg = String(cString: errorBuffer)
					print("Instantiation failed: \(msg)")
					return
				}

//				// 4. Instantiate the module
//				print("Instantiating module...")
//				// Host managed heap size is 0
//				moduleInstance = wasm_runtime_instantiate(module, defaultStackSize, heapSize, &errorBuffer, UInt32(errorBuffer.count))
//
//				guard let instance = moduleInstance else {
//					let errorMsg = String(cString: errorBuffer)
//					print("Error: WAMR failed to instantiate module: \(errorMsg)")
//					return
//				}

				// 5. Create an execution environment (ExecEnv)
				execEnv = wasm_runtime_create_exec_env(instance, defaultStackSize)

				guard let env = execEnv else {
					print("Error: WAMR failed to create execution environment.")
					return
				}

				// 6. Look up the exported "main" function
				let funcName = "_start" // ⬅️ UPDATED: "testadd" to "main"
				let funcInst = wasm_runtime_lookup_function(instance, funcName)

				guard let function = funcInst else {
					print("Error: WAMR failed to find function '\(funcName)'.")
					return
				}

				// 7. Prepare arguments and call the function
				print("Calling exported function '\(funcName)()'...")

				// Signature: () -> i32. Array: [Result: i32]
				var argv: [UInt32] = [0] // ⬅️ UPDATED: Only 1 cell for result
				let argc = UInt32(argv.count)

				// NOTE: Arguments are removed because C/C++ main() takes no arguments (or takes argc/argv, which is a different signature handled specially).

				let success = argv.withUnsafeMutableBufferPointer { argvPtr in
					let argvCArray = argvPtr.baseAddress
					return wasm_runtime_call_wasm(env, function, argc, argvCArray)
				}

				guard success else {
					let exception = wasm_runtime_get_exception(instance)
					let exceptionString = exception != nil ? String(cString: exception!) : "Unknown error"
					print("Error: WASM function call failed: \(exceptionString)")
					return
				}

				// 8. Retrieve the result (the exit code stored in argv[0])
				let result = Int32(argv[0])
				print("Success! WASM execution complete. Exit code: \(result)")
				// If main() prints output, it will appear in the console.
			}
		} catch {
			// self.wasmResult = "Error: \(error.localizedDescription)" // Assuming self.wasmResult is defined elsewhere
			print("Error: \(error.localizedDescription)")
		}

	}
}
