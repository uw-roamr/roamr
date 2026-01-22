//
//  WasmFile.swift
//  roamr
//
//  Firestore WASM file model - mirrors web platform schema
//

import Foundation
import FirebaseFirestore

struct WasmFile: Identifiable, Codable {
    @DocumentID var id: String?
    let name: String
    let fileName: String
    let description: String
    let uploaderId: String
    let uploaderName: String
    let isPublic: Bool
    let storageUrl: String
    let storagePath: String
    let uploadedAt: Timestamp?
    let fileSize: Int
    let downloadCount: Int
    let tags: [String]

    var formattedFileSize: String {
        let bytes = Double(fileSize)
        if bytes == 0 { return "0 B" }
        let k = 1024.0
        let sizes = ["B", "KB", "MB", "GB"]
        let i = Int(floor(log(bytes) / log(k)))
        let size = bytes / pow(k, Double(i))
        return String(format: "%.1f %@", size, sizes[min(i, sizes.count - 1)])
    }

    var formattedDate: String {
        guard let timestamp = uploadedAt else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: timestamp.dateValue())
    }
}
