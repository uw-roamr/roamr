//
//  WasmHubView.swift
//  roamr
//
//  Container view with Hub/Downloaded tabs
//

import SwiftUI

enum WasmHubTab: String, CaseIterable {
    case hub = "Home"
    case downloaded = "Downloaded"
}

struct WasmHubView: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @ObservedObject private var wasmManager = WasmManager.shared
    @State private var selectedTab: WasmHubTab = .hub
    @State private var selectedFile: LocalWasmFile?
    @State private var isMapExpanded = true
    @State private var isConsoleExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "WASM",
                statusText: wasmManager.isRunning ? "Running" : (selectedFile != nil ? "Ready" : "Idle"),
                statusColor: wasmManager.isRunning ? .green : (selectedFile != nil ? .blue : .gray)
            ) {
                if wasmManager.isRunning {
                    Button {
                        stopWasm()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                            .background(Color.red.opacity(0.15))
                            .clipShape(Circle())
                    }
                } else {
                    Button {
                        runSelectedWasm()
                    } label: {
                        PlayButton(isActive: wasmManager.isRunning)
                    }
                    .disabled(selectedFile == nil)
                }
            }

            Picker("Tab", selection: $selectedTab) {
                ForEach(WasmHubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Group {
                switch selectedTab {
                case .hub:
                    BrowseTab(
                        onSelectFile: { file in
                            selectedFile = file
                            selectedTab = .downloaded
                        }
                    )
                case .downloaded:
                    DownloadedTab(
                        selectedFile: $selectedFile,
                        isRunning: wasmManager.isRunning
                    )
                }
            }

            VStack(alignment: .leading, spacing: 12) {
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
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 220)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.06))
                    )
                } label: {
                    Text("WASM Console")
                        .font(.headline)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
    }

    private func runSelectedWasm() {
        guard let file = selectedFile else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            IMUManager.shared.start()
            AVManager.shared.start()

            wasmManager.runWasmFile(at: file.fileURL)

            AVManager.shared.stop()
            IMUManager.shared.stop()
        }
    }

    private func stopWasm() {
        WasmManager.shared.stop()
        AVManager.shared.stop()
        IMUManager.shared.stop()
    }
}
