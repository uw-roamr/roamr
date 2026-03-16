//
//  DownloadManager.swift
//  roamr
//
//  Manages WASM file downloads and local storage
//

import Foundation

@Observable
class DownloadManager {
    static let shared = DownloadManager()

    private let fileManager = FileManager.default
    private let wasmFolderName = "WasmFiles"
    private let indexFileName = "downloaded_files.json"

    private(set) var downloadedFiles: [LocalWasmFile] = []
    private(set) var downloadProgress: [String: Double] = [:]
    private(set) var isDownloading: [String: Bool] = [:]

    private var wasmFolderURL: URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent(wasmFolderName)
    }

    private var indexFileURL: URL {
        wasmFolderURL.appendingPathComponent(indexFileName)
    }

    private init() {
        createWasmFolderIfNeeded()
        loadIndex()
    }

    private func createWasmFolderIfNeeded() {
        if !fileManager.fileExists(atPath: wasmFolderURL.path) {
            try? fileManager.createDirectory(at: wasmFolderURL, withIntermediateDirectories: true)
        }
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexFileURL.path) else {
            downloadedFiles = []
            return
        }

        do {
            let data = try Data(contentsOf: indexFileURL)
            let index = try JSONDecoder().decode(DownloadedFilesIndex.self, from: data)
            downloadedFiles = index.files.filter { $0.exists }

            if downloadedFiles.count != index.files.count {
                saveIndex()
            }
        } catch {
            print("Failed to load download index: \(error)")
            downloadedFiles = []
        }
    }

    private func saveIndex() {
        do {
            let index = DownloadedFilesIndex(files: downloadedFiles)
            let data = try JSONEncoder().encode(index)
            try data.write(to: indexFileURL)
        } catch {
            print("Failed to save download index: \(error)")
        }
    }

    func isDownloaded(fileId: String) -> Bool {
        downloadedFiles.contains { $0.remoteId == fileId }
    }

    func getLocalFile(remoteId: String) -> LocalWasmFile? {
        downloadedFiles.first { $0.remoteId == remoteId }
    }

    func download(file: WasmFile) async throws -> LocalWasmFile {
        guard let fileId = file.id else {
            throw DownloadError.invalidFile
        }

        if let existing = getLocalFile(remoteId: fileId) {
            return existing
        }

        isDownloading[fileId] = true
        downloadProgress[fileId] = 0

        do {
            let data = try await WasmHubService.shared.downloadFile(file) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.downloadProgress[fileId] = progress
                }
            }

            let localFileName = "\(fileId)_\(file.fileName)"
            let localFileURL = wasmFolderURL.appendingPathComponent(localFileName)

            try data.write(to: localFileURL)

            let localFile = LocalWasmFile(
                id: UUID().uuidString,
                remoteId: fileId,
                name: file.name,
                fileName: file.fileName,
                description: file.description,
                uploaderName: file.uploaderName,
                fileSize: file.fileSize,
                downloadedAt: Date(),
                localPath: localFileURL.path
            )

            downloadedFiles.append(localFile)
            saveIndex()

            await WasmHubService.shared.incrementDownloadCount(for: fileId)

            isDownloading[fileId] = false
            downloadProgress.removeValue(forKey: fileId)

            return localFile
        } catch {
            isDownloading[fileId] = false
            downloadProgress.removeValue(forKey: fileId)
            throw error
        }
    }

    func deleteFile(_ localFile: LocalWasmFile) throws {
        if fileManager.fileExists(atPath: localFile.localPath) {
            try fileManager.removeItem(atPath: localFile.localPath)
        }

        downloadedFiles.removeAll { $0.id == localFile.id }
        saveIndex()
    }

    func deleteFile(withRemoteId remoteId: String) throws {
        guard let localFile = getLocalFile(remoteId: remoteId) else { return }
        try deleteFile(localFile)
    }

    func refreshDownloadedFiles() {
        loadIndex()
    }

    enum DownloadError: LocalizedError {
        case invalidFile
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid file ID"
            case .downloadFailed:
                return "Download failed"
            }
        }
    }
}
