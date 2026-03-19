//
//  WasmDebugView.swift
//  roamr
//
//  Debug screen showing map preview, WASM console output, and recording settings.
//

import SwiftUI
import UniformTypeIdentifiers

struct WasmDebugView: View {
    @ObservedObject private var wasmManager = WasmManager.shared
    @State private var isMapExpanded = true
    @State private var isConsoleExpanded = true
    @State private var isRecordingExpanded = false

    @State private var recordingEnabled: Bool = WasmManager.shared.recordingEnabled
    @State private var recordingPath: String = WasmManager.shared.recordingPath
    @State private var selectedRecordingFolderPath: String? = WasmManager.shared.selectedRecordingFolderPath
    @State private var isShowingRecordingFolderPicker = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup(isExpanded: $isMapExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let data = wasmManager.latestMapJPEGData,
                               let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .interpolation(.none)
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                Text("No map frame received yet.")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 160)
                            }

                            Text(
                                "Frames: \(wasmManager.latestMapFrameCount)  Timestamp: " +
                                (wasmManager.latestMapTimestamp > 0
                                    ? String(format: "%.3f", wasmManager.latestMapTimestamp)
                                    : "n/a")
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.06))
                        )
                    } label: {
                        Text("Map Preview")
                            .font(.headline)
                    }

                    DisclosureGroup(isExpanded: $isConsoleExpanded) {
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
                        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 400)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.06))
                        )
                    } label: {
                        Text("WASM Console")
                            .font(.headline)
                    }

                    DisclosureGroup(isExpanded: $isRecordingExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
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

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected folder: \(selectedRecordingFolderPath ?? "None")")
                                Text("Guest path: \(WasmManager.shared.recordingGuestDirectoryPath())")
                                Text("Host path: \(WasmManager.shared.recordingsDirectoryURL()?.path ?? "Unavailable")")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                            Text("Writes IMU, pose, RGB, and point-cloud logs from inside the WASM runtime. Changes apply on next module start.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.06))
                        )
                    } label: {
                        Text("Recording")
                            .font(.headline)
                    }
                }
                .padding()
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
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
                // silently ignore
            }
        }
    }
}
