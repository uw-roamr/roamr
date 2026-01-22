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
    @State private var selectedTab: WasmHubTab = .hub
    @State private var isRunning = false
    @State private var selectedFile: LocalWasmFile?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "WASM",
                statusText: isRunning ? "Running" : (selectedFile != nil ? "Ready" : "Idle"),
                statusColor: isRunning ? .green : (selectedFile != nil ? .blue : .gray)
            ) {
                if isRunning {
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
                        PlayButton(isActive: isRunning)
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
                        isRunning: isRunning
                    )
                }
            }
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
    }

    private func runSelectedWasm() {
        guard let file = selectedFile else { return }

        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            IMUManager.shared.start()
            AVManager.shared.start()

            WasmManager.shared.runWasmFile(at: file.fileURL)

            AVManager.shared.stop()
            IMUManager.shared.stop()

            DispatchQueue.main.async {
                isRunning = false
            }
        }
    }

    private func stopWasm() {
        WasmManager.shared.stop()
        AVManager.shared.stop()
        IMUManager.shared.stop()
    }
}
