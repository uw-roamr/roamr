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
				runTest()
			}
			.padding()
			.background(Color.AppColor.accent.color)
			.foregroundColor(.white)
			.cornerRadius(20)

			Spacer()
		}
		.padding()
	}

	func runTest() {
		// userInitiated gives high priority to the thread
        DispatchQueue.global(qos: .userInitiated).async {
            IMUManager.shared.start()
            LidarCameraManager.shared.start()

            WasmManager.shared.runWasmFile(named: "slam_main")

            LidarCameraManager.shared.stop()
            IMUManager.shared.stop()
        }
    }
}
