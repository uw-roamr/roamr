//
//  MLBundleManager.swift
//  roamr
//
//  Imports and stores local WASM ML bundles.
//

import Foundation

@Observable
final class MLBundleManager {
    static let shared = MLBundleManager()

    private struct ManifestProbe: Decodable {
        let modelFile: String

        private enum CodingKeys: String, CodingKey {
            case modelFile = "model_file"
        }
    }

    enum BundleError: LocalizedError {
        case accessDenied
        case invalidBundle(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Access to the selected folder was denied."
            case .invalidBundle(let message):
                return message
            }
        }
    }

    private struct ValidatedBundle {
        let entryWasmFileName: String
        let byteCount: Int
    }

    private let fileManager = FileManager.default
    private let bundlesFolderName = "WasmBundles"
    private let indexFileName = "imported_bundles.json"

    private(set) var importedBundles: [LocalWasmBundle] = []

    private var bundlesFolderURL: URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent(bundlesFolderName, isDirectory: true)
    }

    private var indexFileURL: URL {
        bundlesFolderURL.appendingPathComponent(indexFileName, isDirectory: false)
    }

    private init() {
        createBundlesFolderIfNeeded()
        loadIndex()
    }

    func refreshBundles() {
        loadIndex()
    }

    func importBundle(from sourceURL: URL) throws -> LocalWasmBundle {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard accessedSecurityScope || sourceURL.isFileURL else {
            throw BundleError.accessDenied
        }

        let validatedBundle = try validateBundle(at: sourceURL)
        createBundlesFolderIfNeeded()

        let destinationURL = bundlesFolderURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let bundle = LocalWasmBundle(
            id: UUID().uuidString,
            name: sourceURL.lastPathComponent,
            entryWasmFileName: validatedBundle.entryWasmFileName,
            importedAt: Date(),
            localPath: destinationURL.path,
            byteCount: validatedBundle.byteCount
        )

        importedBundles.append(bundle)
        importedBundles.sort { $0.importedAt > $1.importedAt }
        saveIndex()
        return bundle
    }

    func deleteBundle(_ bundle: LocalWasmBundle) throws {
        if fileManager.fileExists(atPath: bundle.localPath) {
            try fileManager.removeItem(atPath: bundle.localPath)
        }
        importedBundles.removeAll { $0.id == bundle.id }
        saveIndex()
    }

    private func createBundlesFolderIfNeeded() {
        if !fileManager.fileExists(atPath: bundlesFolderURL.path) {
            try? fileManager.createDirectory(at: bundlesFolderURL, withIntermediateDirectories: true)
        }
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexFileURL.path) else {
            importedBundles = []
            return
        }

        do {
            let data = try Data(contentsOf: indexFileURL)
            let index = try JSONDecoder().decode(ImportedWasmBundlesIndex.self, from: data)
            importedBundles = index.bundles.filter { $0.exists }
            if importedBundles.count != index.bundles.count {
                saveIndex()
            }
        } catch {
            importedBundles = []
        }
    }

    private func saveIndex() {
        do {
            let index = ImportedWasmBundlesIndex(bundles: importedBundles)
            let data = try JSONEncoder().encode(index)
            try data.write(to: indexFileURL)
        } catch {
            print("Failed to save imported bundle index: \(error)")
        }
    }

    private func validateBundle(at sourceURL: URL) throws -> ValidatedBundle {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BundleError.invalidBundle("Select a folder that contains a WASM bundle.")
        }

        let topLevelContents = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let topLevelWasmFiles = topLevelContents
            .filter { $0.pathExtension == "wasm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !topLevelWasmFiles.isEmpty else {
            throw BundleError.invalidBundle("The selected folder must contain a .wasm file at its top level.")
        }

        let entryWasmURL = topLevelWasmFiles.first { $0.lastPathComponent == "stop_sign_main.wasm" } ?? topLevelWasmFiles[0]

        let manifestURLs = try recursiveFiles(
            under: sourceURL,
            matching: { $0.lastPathComponent == "manifest.json" }
        )
        guard !manifestURLs.isEmpty else {
            throw BundleError.invalidBundle("The selected folder must contain at least one manifest.json file.")
        }

        var hasModel = false
        for manifestURL in manifestURLs {
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(ManifestProbe.self, from: data)
            else {
                continue
            }

            let modelURL: URL
            if manifest.modelFile.hasPrefix("/") {
                modelURL = URL(fileURLWithPath: manifest.modelFile, isDirectory: false)
            } else {
                modelURL = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.modelFile, isDirectory: false)
            }

            if fileManager.fileExists(atPath: modelURL.path) {
                hasModel = true
                break
            }
        }

        guard hasModel else {
            throw BundleError.invalidBundle("No manifest.json in the selected folder points to an existing model file.")
        }

        return ValidatedBundle(
            entryWasmFileName: entryWasmURL.lastPathComponent,
            byteCount: try directoryByteCount(at: sourceURL)
        )
    }

    private func recursiveFiles(
        under rootURL: URL,
        matching predicate: (URL) -> Bool
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true && predicate(fileURL) {
                results.append(fileURL)
            }
        }
        return results
    }

    private func directoryByteCount(at rootURL: URL) throws -> Int {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var byteCount = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                byteCount += values.fileSize ?? 0
            }
        }
        return byteCount
    }
}
