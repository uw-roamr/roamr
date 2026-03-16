//
//  LocalWasmFile.swift
//  roamr
//
//  Model for locally downloaded WASM files
//

import Foundation

struct LocalWasmFile: Identifiable, Codable {
    let id: String
    let remoteId: String
    let name: String
    let fileName: String
    let description: String
    let uploaderName: String
    let fileSize: Int
    let downloadedAt: Date
    let localPath: String

    var fileURL: URL {
        URL(fileURLWithPath: localPath)
    }

    var formattedFileSize: String {
        let bytes = Double(fileSize)
        if bytes == 0 { return "0 B" }
        let k = 1024.0
        let sizes = ["B", "KB", "MB", "GB"]
        let i = Int(floor(log(bytes) / log(k)))
        let size = bytes / pow(k, Double(i))
        return String(format: "%.1f %@", size, sizes[min(i, sizes.count - 1)])
    }

    var formattedDownloadDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: downloadedAt)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: localPath)
    }
}

struct DownloadedFilesIndex: Codable {
    var files: [LocalWasmFile]
}
