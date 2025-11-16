//
//  SettingsPage.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import Foundation
import SwiftUI
import WasmKit

struct SettingsPage: View {
	@EnvironmentObject var lidarManager: LiDARManager
	@State private var wasmRunner: WasmRunner?
	@State private var wasmResult: String = "..."

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

			Text("Result: \(wasmResult)")
				.font(.title2)

			Button("Run processData") {
				try? self.test()
			}
			.font(.title)
			.padding()
			.background(Color.blue)
			.foregroundColor(.white)
			.cornerRadius(10)

			Spacer()
		}
		.padding()
		.onAppear {
//			self.loadRunner()
		}
	}

	func test() throws {
		do {
			// --- Step 1: Find and load the .wasm file ---
			guard let wasmURL = Bundle.main.url(forResource: "add", withExtension: "wasm") else {
				self.wasmResult = "Error: add.wasm file not found in bundle."
				return
			}
			let wasmBytes = try Data(contentsOf: wasmURL)

			// --- Step 2: Initialize WasmKit Runtime ---
			let runtime = Engine()
			let module: Module = try parseWasm(bytes: [UInt8](wasmBytes))

			// --- Step 4: Find the exported 'add' function ---
			let engine = Engine()
			let store = Store(engine: engine)
			let instance = try module.instantiate(store: store)
			let input: UInt32 = 5
			// Invoke the exported function "fac" with a single argument.
			let testadd = instance.exports[function: "testadd"]!
			let result = try testadd([.i32(6), .i32(7)])
			print("added(\(input)) = \(result[0].i32)")

		} catch {
			// --- Error Handling ---
			self.wasmResult = "Error: \(error.localizedDescription)"
		}
	}
}
