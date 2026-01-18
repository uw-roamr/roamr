//
//  WasmView.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import SwiftUI

struct WasmView: View {
	@Environment(\.safeAreaInsets) private var safeAreaInsets
	@State private var isRunning = false

	var body: some View {
		VStack {
			PageHeader(
				title: "WASM",
				statusText: isRunning ? "Running" : "Idle",
				statusColor: isRunning ? .green : .gray
			) {
				Button {
					runWasm()
				} label: {
					PlayButton(isActive: isRunning)
				}
				.disabled(isRunning)
			}

			Spacer()

			VStack(spacing: 16) {
				Image(systemName: "doc.badge.plus")
					.font(.system(size: 48))
					.foregroundColor(.gray.opacity(0.5))

				Text("Upload WASM File")
					.font(.headline)
					.foregroundColor(.gray)

				Text("Select a .wasm file to run")
					.font(.caption)
					.foregroundColor(.gray.opacity(0.7))
			}

			Spacer()
		}
		.padding(.top, safeAreaInsets.top)
		.padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
	}

	func runWasm() {
		isRunning = true
		DispatchQueue.global(qos: .userInitiated).async {
			IMUManager.shared.start()
			AVManager.shared.start()

			WasmManager.shared.runWasmFile(named: "slam_main")

			AVManager.shared.stop()
			IMUManager.shared.stop()

			DispatchQueue.main.async {
				isRunning = false
			}
		}
	}
}
