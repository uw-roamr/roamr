//
//  MLBundlesTab.swift
//  roamr
//
//  Import and run local WASM ML bundles.
//

import SwiftUI
import UniformTypeIdentifiers

struct MLBundlesTab: View {
    @Binding var selectedBundle: LocalWasmBundle?
    let isRunning: Bool

    @State private var isShowingImporter = false
    @State private var bundleToDelete: LocalWasmBundle?
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    private var bundleManager: MLBundleManager { MLBundleManager.shared }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Import a folder that contains a top-level .wasm file and its ML sidecar assets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Import Bundle") {
                    isShowingImporter = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if bundleManager.importedBundles.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(bundleManager.importedBundles) { bundle in
                            LocalWasmBundleRow(
                                bundle: bundle,
                                isSelected: selectedBundle?.id == bundle.id,
                                onSelect: {
                                    if !isRunning {
                                        selectedBundle = bundle
                                    }
                                },
                                onDelete: {
                                    bundleToDelete = bundle
                                    showDeleteConfirmation = true
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            bundleManager.refreshBundles()
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                let bundle = try bundleManager.importBundle(from: url)
                selectedBundle = bundle
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Delete Bundle", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                bundleToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let bundle = bundleToDelete {
                    deleteBundle(bundle)
                }
            }
        } message: {
            Text("Delete this imported ML bundle? This removes the local copy from the app.")
        }
        .alert("Import Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Imported ML Bundles")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Import a local folder bundle to run a .wasm file with its model bundle sidecars.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteBundle(_ bundle: LocalWasmBundle) {
        if selectedBundle?.id == bundle.id {
            selectedBundle = nil
        }

        do {
            try bundleManager.deleteBundle(bundle)
        } catch {
            errorMessage = error.localizedDescription
        }

        bundleToDelete = nil
    }
}
