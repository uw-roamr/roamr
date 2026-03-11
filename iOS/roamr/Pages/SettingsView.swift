//
//  SettingsPage.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
	@State private var rerunURL: String = RerunWebSocketClient.shared.serverURLString
    @State private var recordingEnabled: Bool = WasmManager.shared.recordingEnabled
    @State private var recordingPath: String = WasmManager.shared.recordingPath
    @State private var selectedRecordingFolderPath: String? = WasmManager.shared.selectedRecordingFolderPath
    @State private var isShowingRecordingFolderPicker = false

    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var authManager: AuthManager { AuthManager.shared }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Settings",
                statusText: authManager.isAuthenticated ? "\(authManager.email)" : "Not signed in",
                statusColor: authManager.isAuthenticated ? .green : .gray
            ) {
                ProfileButton(isAuthenticated: authManager.isAuthenticated)
            }

            ScrollView {
                VStack(spacing: 24) {
                    rerunSection
                    recordingSection
                    appInfoSection
                    accountSection
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
	    .onAppear {
			rerunURL = RerunWebSocketClient.shared.serverURLString
            recordingEnabled = WasmManager.shared.recordingEnabled
            recordingPath = WasmManager.shared.recordingPath
            selectedRecordingFolderPath = WasmManager.shared.selectedRecordingFolderPath
		}
        .fileImporter(
            isPresented: $isShowingRecordingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                try WasmManager.shared.setRecordingFolderURL(url)
                selectedRecordingFolderPath = WasmManager.shared.selectedRecordingFolderPath
            } catch {
                errorMessage = "Folder selection failed: \(error.localizedDescription)"
            }
        }
    }

	@ViewBuilder
	private var rerunSection: some View {
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
	}

    @ViewBuilder
    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WASM Recording")
                .font(.headline)

            Toggle("Enable sensor recording", isOn: $recordingEnabled)
                .onChange(of: recordingEnabled) { _, isEnabled in
                    WasmManager.shared.setRecordingEnabled(isEnabled)
                }

            TextField("Recording path", text: $recordingPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button("Apply Path") {
                    WasmManager.shared.setRecordingPath(recordingPath)
                    recordingPath = WasmManager.shared.recordingPath
                }
                .buttonStyle(.borderedProminent)

                Button("Reset Path") {
                    WasmManager.shared.resetRecordingPath()
                    recordingPath = WasmManager.shared.recordingPath
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                Button("Choose Folder") {
                    isShowingRecordingFolderPicker = true
                }
                .buttonStyle(.borderedProminent)

                Button("Clear Folder") {
                    WasmManager.shared.clearRecordingFolderSelection()
                    selectedRecordingFolderPath = WasmManager.shared.selectedRecordingFolderPath
                }
                .buttonStyle(.bordered)
                .disabled(selectedRecordingFolderPath == nil)
            }

            Text("Writes IMU and LiDAR/depth logs from inside the WASM runtime.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Choose Folder lets you target Files locations such as Downloads. If no folder is selected, the text path below uses an app-local directory.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Selected folder: \(selectedRecordingFolderPath ?? "None")")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            Text("Guest path: \(WasmManager.shared.recordingGuestDirectoryPath())")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Host path: \(WasmManager.shared.recordingsDirectoryURL()?.path ?? "Unavailable")")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            Text("Applies the next time a WASM module starts.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(spacing: 16) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if authManager.isAuthenticated {
                // Signed in - show sign out button
				Button {
					signOut()
				} label: {
					HStack(spacing: 10) {
						Image(systemName: "rectangle.portrait.and.arrow.right")
							.font(.body)
						Text("Sign Out")
							.fontWeight(.medium)
					}
					.padding(.horizontal, 20)
					.padding(.vertical, 14)
					.background(Color.red)
					.foregroundStyle(.white)
					.clipShape(Capsule())
					.overlay(
						Capsule()
							.stroke(Color.gray.opacity(0.5), lineWidth: 1)
					)
				}
            } else {
                // Not signed in - show Google sign in button
                    Button {
                        Task {
                            await signInWithGoogle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image("google")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                            Text(isLoading ? "Signing in..." : "Sign in with Google")
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .disabled(isLoading)
            }
        }
    }

    @ViewBuilder
    private var appInfoSection: some View {
        VStack(spacing: 16) {
            Text("roamr")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Really Open-Source Autonomous Robot")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
        }
    }

    private func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil

        do {
            try await AuthManager.shared.signInWithGoogle()
        } catch {
            errorMessage = AuthManager.shared.error ?? error.localizedDescription
        }

        isLoading = false
    }

    private func signOut() {
        do {
            try authManager.signOut()
            errorMessage = nil
        } catch {
            errorMessage = "Sign out failed"
        }
    }
}

struct ProfileButton: View {
    let isAuthenticated: Bool

    var body: some View {
        Image(systemName: isAuthenticated ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
            .font(.title)
            .foregroundStyle(isAuthenticated ? .green : .secondary)
            .frame(width: 44, height: 44)
            .background(isAuthenticated ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
            .clipShape(Circle())
    }
}
