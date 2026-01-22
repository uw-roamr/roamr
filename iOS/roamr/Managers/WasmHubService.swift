//
//  WasmHubService.swift
//  roamr
//
//  Firestore queries for WASM files and Firebase Storage downloads
//

import Foundation
import FirebaseFirestore
import FirebaseStorage

@Observable
class WasmHubService {
    static let shared = WasmHubService()

    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    private let collectionName = "wasmFiles"

    private(set) var publicFiles: [WasmFile] = []
    private(set) var userFiles: [WasmFile] = []
    private(set) var isLoadingPublic = false
    private(set) var isLoadingUser = false
    private(set) var error: String?

    private init() {}

    func fetchPublicFiles() async {
        isLoadingPublic = true
        error = nil

        do {
            let snapshot = try await db.collection(collectionName)
                .whereField("isPublic", isEqualTo: true)
                .order(by: "uploadedAt", descending: true)
                .getDocuments()

            publicFiles = snapshot.documents.compactMap { doc in
                try? doc.data(as: WasmFile.self)
            }
            isLoadingPublic = false
        } catch {
            self.error = error.localizedDescription
            isLoadingPublic = false
        }
    }

    func fetchUserFiles(userId: String) async {
        isLoadingUser = true
        error = nil

        do {
            let snapshot = try await db.collection(collectionName)
                .whereField("uploaderId", isEqualTo: userId)
                .order(by: "uploadedAt", descending: true)
                .getDocuments()

            userFiles = snapshot.documents.compactMap { doc in
                try? doc.data(as: WasmFile.self)
            }
            isLoadingUser = false
        } catch {
            self.error = error.localizedDescription
            isLoadingUser = false
        }
    }

    func getDownloadURL(for file: WasmFile) async throws -> URL {
        let storageRef = storage.reference(withPath: file.storagePath)
        return try await storageRef.downloadURL()
    }

    func downloadFile(_ file: WasmFile, progress: ((Double) -> Void)? = nil) async throws -> Data {
        let storageRef = storage.reference(withPath: file.storagePath)
        let maxSize: Int64 = 50 * 1024 * 1024

        return try await withCheckedThrowingContinuation { continuation in
            let downloadTask = storageRef.getData(maxSize: maxSize) { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "WasmHubService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }

            downloadTask.observe(.progress) { snapshot in
                guard let progressValue = snapshot.progress else { return }
                let percent = Double(progressValue.completedUnitCount) / Double(progressValue.totalUnitCount)
                progress?(percent)
            }
        }
    }

    func incrementDownloadCount(for fileId: String) async {
        do {
            try await db.collection(collectionName).document(fileId).updateData([
                "downloadCount": FieldValue.increment(Int64(1))
            ])
        } catch {
            print("Failed to increment download count: \(error)")
        }
    }

    func searchFiles(query: String, isPublic: Bool = true) async -> [WasmFile] {
        let lowercaseQuery = query.lowercased()
        let files = isPublic ? publicFiles : userFiles

        return files.filter { file in
            file.name.lowercased().contains(lowercaseQuery) ||
            file.description.lowercased().contains(lowercaseQuery) ||
            file.tags.contains { $0.lowercased().contains(lowercaseQuery) }
        }
    }
}
