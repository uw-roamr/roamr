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
    case mlBundles = "ML"
}

struct WasmHubView: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @ObservedObject private var wasmManager = WasmManager.shared
    @State private var selectedTab: WasmHubTab = .hub
    @State private var selectedFile: LocalWasmFile?
    @State private var selectedBundle: LocalWasmBundle?
    @State private var isDebugPresented = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "WASM",
                statusText: wasmManager.isRunning ? "Running" : (hasRunnableSelection ? "Ready" : "Idle"),
                statusColor: wasmManager.isRunning ? .green : (hasRunnableSelection ? .blue : .gray),
                titleAccessory: AnyView(
                    Button {
                        isDebugPresented = true
                    } label: {
                        Image(systemName: "ant.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        }
                )
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
                    .disabled(!hasRunnableSelection)
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
                case .mlBundles:
                    MLBundlesTab(
                        selectedBundle: $selectedBundle,
                        isRunning: wasmManager.isRunning
                    )
                }
            }

        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
        .sheet(isPresented: $isDebugPresented) {
            WasmDebugView()
        }
        .onChange(of: selectedFile) { _, file in
            if file != nil {
                selectedBundle = nil
            }
        }
        .onChange(of: selectedBundle) { _, bundle in
            if bundle != nil {
                selectedFile = nil
            }
        }
    }

    private var hasRunnableSelection: Bool {
        selectedFile != nil || selectedBundle != nil
    }

    private func runSelectedWasm() {
        let wasmURL: URL
        if let bundle = selectedBundle {
            wasmURL = bundle.entryWasmURL
        } else if let file = selectedFile {
            wasmURL = file.fileURL
        } else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            wasmManager.startConfiguredHostSensors()

            wasmManager.runWasmFile(at: wasmURL)

            wasmManager.stopConfiguredHostSensors()
        }
    }

    private func stopWasm() {
        WasmManager.shared.stop()
        WasmManager.shared.stopConfiguredHostSensors()
    }
}
