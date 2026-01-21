//
//  DownloadedTab.swift
//  roamr
//
//  Manage and run downloaded WASM files
//

import SwiftUI

struct DownloadedTab: View {
    @Binding var selectedFile: LocalWasmFile?
    let isRunning: Bool

    @State private var showDeleteConfirmation = false
    @State private var fileToDelete: LocalWasmFile?

    private var downloadManager: DownloadManager { DownloadManager.shared }

    var body: some View {
        VStack {
            if downloadManager.downloadedFiles.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(downloadManager.downloadedFiles) { file in
                            LocalWasmFileRow(
                                file: file,
                                isSelected: selectedFile?.id == file.id,
                                onSelect: {
                                    if !isRunning {
                                        selectedFile = file
                                    }
                                },
                                onDelete: {
                                    fileToDelete = file
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
            downloadManager.refreshDownloadedFiles()
        }
        .alert("Delete File", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                fileToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
        } message: {
            if let file = fileToDelete {
                Text("Are you sure you want to delete \"\(file.name)\"? This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Downloaded Files")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Download WASM files from the Hub tab to run them here")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteFile(_ file: LocalWasmFile) {
        if selectedFile?.id == file.id {
            selectedFile = nil
        }

        do {
            try downloadManager.deleteFile(file)
        } catch {
            print("Failed to delete file: \(error)")
        }

        fileToDelete = nil
    }
}
