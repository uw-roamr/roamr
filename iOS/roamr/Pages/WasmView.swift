//
//  WasmView.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import SwiftUI

struct WasmView: View {
	@Environment(\.safeAreaInsets) private var safeAreaInsets
	@ObservedObject private var wasmManager = WasmManager.shared

	var body: some View {
		VStack {
			PageHeader(
				title: "WASM",
				statusText: wasmManager.isRunning ? "Running" : "Idle",
				statusColor: wasmManager.isRunning ? .green : .gray
			) {
				Button {
					runWasm()
				} label: {
					PlayButton(isActive: wasmManager.isRunning)
				}
				.disabled(wasmManager.isRunning)
			}

			VStack(alignment: .leading, spacing: 12) {
				Text("WASM Console")
					.font(.headline)

				ScrollView {
					VStack(alignment: .leading, spacing: 8) {
						if wasmManager.logLines.isEmpty {
							Text("Run a WASM module to see host-side logs from the module here.")
								.foregroundColor(.secondary)
						} else {
							ForEach(Array(wasmManager.logLines.enumerated()), id: \.offset) { _, line in
								Text(line)
									.font(.system(.caption, design: .monospaced))
									.foregroundColor(.primary)
									.frame(maxWidth: .infinity, alignment: .leading)
							}
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(12)
				.background(
					RoundedRectangle(cornerRadius: 16)
						.fill(Color.black.opacity(0.06))
				)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.padding(.horizontal, 20)
		}
		.padding(.top, safeAreaInsets.top)
		.padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
	}

	func runWasm() {
		DispatchQueue.global(qos: .userInitiated).async {
			wasmManager.startConfiguredHostSensors()

			wasmManager.runWasmFile(named: "slam_main")

			wasmManager.stopConfiguredHostSensors()
		}
	}
}
