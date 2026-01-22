//
//  SettingsPage.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import Foundation
import SwiftUI

struct SettingsPage: View {
	@State private var rerunURL: String = RerunWebSocketClient.shared.serverURLString

	private var appVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
	}

	var body: some View {
		VStack(spacing: 30) {
			Spacer()

			VStack(alignment: .leading, spacing: 12) {
				Text("Rerun WebSocket")
					.font(.headline)
				TextField("ws://host:port", text: $rerunURL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled(true)
					.keyboardType(.URL)
					.textFieldStyle(.roundedBorder)
				Text("Default: \(RerunWebSocketClient.defaultServerURLString)")
					.font(.caption)
					.foregroundColor(.secondary)
				Button("Apply") {
					RerunWebSocketClient.shared.updateServerURL(rerunURL)
				}
				.buttonStyle(.borderedProminent)
				Button("Reset to Default") {
					rerunURL = RerunWebSocketClient.defaultServerURLString
					RerunWebSocketClient.shared.updateServerURL(rerunURL)
				}
				.buttonStyle(.bordered)
			}
			.padding()
			.background(Color(.systemGray6))
			.cornerRadius(12)
			.padding(.horizontal)

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

			Spacer()
		}
		.padding()
		.onAppear {
			rerunURL = RerunWebSocketClient.shared.serverURLString
		}
	}
}
