//
//  BrowseTab.swift
//  roamr
//
//  Browse public/private WASM files from the hub
//

import SwiftUI

enum BrowseFilter: String, CaseIterable {
    case publicFiles = "Public"
    case myFiles = "My Files"
}

struct BrowseTab: View {
    @State private var searchText = ""
    @State private var selectedFilter: BrowseFilter = .publicFiles
    @State private var errorMessage: String?

    let onSelectFile: (LocalWasmFile) -> Void

    private var wasmHubService: WasmHubService { WasmHubService.shared }
    private var downloadManager: DownloadManager { DownloadManager.shared }
    private var authManager: AuthManager { AuthManager.shared }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // Filter chips at top
                if authManager.isAuthenticated {
                    HStack(spacing: 8) {
                        ForEach(BrowseFilter.allCases, id: \.self) { filter in
                            FilterChip(
                                title: filter.rawValue,
                                isSelected: selectedFilter == filter
                            ) {
                                selectedFilter = filter
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    if isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else if filteredFiles.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(filteredFiles) { file in
                            WasmFileRow(
                                file: file,
                                isDownloaded: downloadManager.isDownloaded(fileId: file.id ?? ""),
                                isDownloading: downloadManager.isDownloading[file.id ?? ""] ?? false,
                                downloadProgress: downloadManager.downloadProgress[file.id ?? ""] ?? 0,
                                onDownload: {
                                    Task {
                                        await downloadFile(file)
                                    }
                                },
                                onRun: {
                                    if let localFile = downloadManager.getLocalFile(remoteId: file.id ?? "") {
                                        onSelectFile(localFile)
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .task {
            await loadFiles()
        }
        .refreshable {
            await loadFiles()
        }
        .onChange(of: selectedFilter) { _, _ in
            Task {
                await loadFiles()
            }
        }
    }

    private var isLoading: Bool {
        selectedFilter == .publicFiles ? wasmHubService.isLoadingPublic : wasmHubService.isLoadingUser
    }

    private var files: [WasmFile] {
        selectedFilter == .publicFiles ? wasmHubService.publicFiles : wasmHubService.userFiles
    }

    private var filteredFiles: [WasmFile] {
        guard !searchText.isEmpty else { return files }
        let query = searchText.lowercased()
        return files.filter { file in
            file.name.lowercased().contains(query) ||
            file.description.lowercased().contains(query) ||
            file.tags.contains { $0.lowercased().contains(query) }
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedFilter == .myFiles ? "folder.badge.person.crop" : "globe")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if selectedFilter == .myFiles && !authManager.isAuthenticated {
                Text("Sign in to see your files")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No WASM files found")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(selectedFilter == .myFiles ? "Upload files on the web to see them here" : "Be the first to upload!")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 60)
    }

    private func loadFiles() async {
        errorMessage = nil

        if selectedFilter == .publicFiles {
            await wasmHubService.fetchPublicFiles()
        } else if let userId = authManager.currentUser?.uid {
            await wasmHubService.fetchUserFiles(userId: userId)
        }

        if let error = wasmHubService.error {
            errorMessage = error
        }
    }

    private func downloadFile(_ file: WasmFile) async {
        do {
            let localFile = try await downloadManager.download(file: file)
            onSelectFile(localFile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color("AccentColor") : Color.gray.opacity(0.4))
                .foregroundStyle(isSelected ? .white : .secondary)
                .clipShape(Capsule())
        }
    }
}
