//
//  LocalWasmBundle.swift
//  roamr
//
//  Model for locally imported WASM ML bundles
//

import Foundation

struct LocalWasmBundle: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let entryWasmFileName: String
    let importedAt: Date
    let localPath: String
    let byteCount: Int

    var bundleURL: URL {
        URL(fileURLWithPath: localPath, isDirectory: true)
    }

    var entryWasmURL: URL {
        bundleURL.appendingPathComponent(entryWasmFileName, isDirectory: false)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: localPath)
    }

    var formattedFileSize: String {
        let bytes = Double(byteCount)
        if bytes == 0 { return "0 B" }
        let unit = 1024.0
        let labels = ["B", "KB", "MB", "GB"]
        let index = Int(floor(log(bytes) / log(unit)))
        let size = bytes / pow(unit, Double(index))
        return String(format: "%.1f %@", size, labels[min(index, labels.count - 1)])
    }

    var formattedImportDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: importedAt)
    }
}

struct ImportedWasmBundlesIndex: Codable {
    var bundles: [LocalWasmBundle]
}
