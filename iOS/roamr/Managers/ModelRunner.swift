//
//  ModelRunner.swift
//  roamr
//
//  Dynamic model loading and camera-frame inference for WASM policies.
//

import Foundation

#if canImport(ExecuTorch)
import ExecuTorch
#endif

enum ModelRunnerStatus: Int32 {
    case success = 0
    case notFound = -1
    case invalidManifest = -2
    case unsupportedTask = -3
    case runtimeUnavailable = -4
    case invalidModel = -5
    case noFrameAvailable = -6
    case inferenceFailed = -7
    case unsupportedBackend = -8
    case badRequest = -9
}

struct ModelDetection {
    var classId: Int32
    var score: Float
    var xMin: Float
    var yMin: Float
    var xMax: Float
    var yMax: Float
    var labelName: String? = nil
}

struct ModelFrameDetections {
    var status: ModelRunnerStatus
    var frameTimestamp: Double
    var imageWidth: Int32
    var imageHeight: Int32
    var detections: [ModelDetection]
}

struct ActiveModelFrameDetections {
    var modelId: Int32
    var modelName: String
    var manifestName: String
    var result: ModelFrameDetections
}

struct ModelBundleManifest: Decodable {
    struct InputConfig: Decodable {
        var width: Int
        var height: Int
        var channels: Int = 3
        var resizeMode: String = "stretch"
        var valueScale: Float = 1.0 / 255.0
        var mean: [Float] = [0, 0, 0]
        var std: [Float] = [1, 1, 1]

        init() {
            width = 0
            height = 0
        }

        private enum CodingKeys: String, CodingKey {
            case width
            case height
            case channels
            case resizeMode = "resize_mode"
            case valueScale = "value_scale"
            case mean
            case std
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decode(Int.self, forKey: .width)
            height = try container.decode(Int.self, forKey: .height)
            channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 3
            resizeMode = try container.decodeIfPresent(String.self, forKey: .resizeMode) ?? "stretch"
            valueScale = try container.decodeIfPresent(Float.self, forKey: .valueScale) ?? (1.0 / 255.0)
            mean = try container.decodeIfPresent([Float].self, forKey: .mean) ?? [0, 0, 0]
            std = try container.decodeIfPresent([Float].self, forKey: .std) ?? [1, 1, 1]
        }
    }

    struct OutputConfig: Decodable {
        var elementsPerDetection: Int = 6
        var maxDetections: Int = 32
        var normalizedBoxes: Bool = true

        init() {}

        private enum CodingKeys: String, CodingKey {
            case elementsPerDetection = "elements_per_detection"
            case maxDetections = "max_detections"
            case normalizedBoxes = "normalized_boxes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            elementsPerDetection = try container.decodeIfPresent(Int.self, forKey: .elementsPerDetection) ?? 6
            maxDetections = try container.decodeIfPresent(Int.self, forKey: .maxDetections) ?? 32
            normalizedBoxes = try container.decodeIfPresent(Bool.self, forKey: .normalizedBoxes) ?? true
        }
    }

    var version: Int = 1
    var name: String
    var task: String
    var backend: String
    var delegate: String?
    var method: String = "forward"
    var modelFile: String
    var labelsFile: String?
    var scoreThreshold: Float = 0.5
    var input: InputConfig
    var output: OutputConfig

    private enum CodingKeys: String, CodingKey {
        case version
        case name
        case task
        case backend
        case delegate
        case method
        case modelFile = "model_file"
        case labelsFile = "labels_file"
        case scoreThreshold = "score_threshold"
        case input
        case output
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try container.decode(String.self, forKey: .name)
        task = try container.decode(String.self, forKey: .task)
        backend = try container.decode(String.self, forKey: .backend)
        delegate = try container.decodeIfPresent(String.self, forKey: .delegate)
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "forward"
        modelFile = try container.decode(String.self, forKey: .modelFile)
        labelsFile = try container.decodeIfPresent(String.self, forKey: .labelsFile)
        scoreThreshold = try container.decodeIfPresent(Float.self, forKey: .scoreThreshold) ?? 0.5
        input = try container.decode(InputConfig.self, forKey: .input)
        output = try container.decodeIfPresent(OutputConfig.self, forKey: .output) ?? OutputConfig()
    }
}

enum ModelRunnerError: LocalizedError {
    case invalidManifest(String)
    case unsupportedTask(String)
    case unsupportedBackend(String)
    case runtimeUnavailable(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let message),
             .unsupportedTask(let message),
             .unsupportedBackend(let message),
             .runtimeUnavailable(let message),
             .inferenceFailed(let message):
            return message
        }
    }

    var status: ModelRunnerStatus {
        switch self {
        case .invalidManifest:
            return .invalidManifest
        case .unsupportedTask:
            return .unsupportedTask
        case .unsupportedBackend:
            return .unsupportedBackend
        case .runtimeUnavailable:
            return .runtimeUnavailable
        case .inferenceFailed:
            return .inferenceFailed
        }
    }
}

private protocol ObjectDetectionBackend {
    func predictDetections(frame: CameraImageFrame) throws -> [ModelDetection]
}

private struct DetectionLabelLookup {
    let explicitLabels: [Int32: String]
    let indexedLabels: [String]
    let indexBase: Int32

    func labelName(for classId: Int32) -> String? {
        if let explicit = sanitizedLabel(explicitLabels[classId]) {
            return explicit
        }

        let labelIndex = Int(classId - indexBase)
        guard labelIndex >= 0, labelIndex < indexedLabels.count else {
            return nil
        }
        return sanitizedLabel(indexedLabels[labelIndex])
    }

    private func sanitizedLabel(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lowered = trimmed.lowercased()
        if lowered == "n/a" || lowered == "na" || lowered == "none" {
            return nil
        }
        return trimmed
    }
}

private final class LoadedObjectDetectionModel {
    let id: Int32
    let manifestURL: URL
    let manifest: ModelBundleManifest
    private let backend: ObjectDetectionBackend
    private let labelLookup: DetectionLabelLookup?
    private let queue: DispatchQueue

    private var cachedFrameTimestamp: Double = 0
    private var cachedFrameWidth: Int32 = 0
    private var cachedFrameHeight: Int32 = 0
    private var cachedDetections: [ModelDetection] = []

    init(
        id: Int32,
        manifestURL: URL,
        manifest: ModelBundleManifest,
        backend: ObjectDetectionBackend,
        labelLookup: DetectionLabelLookup?
    ) {
        self.id = id
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.backend = backend
        self.labelLookup = labelLookup
        self.queue = DispatchQueue(label: "com.roamr.modelrunner.model.\(id)")
    }

    func runLatestFrame(_ frame: CameraImageFrame) -> ModelFrameDetections {
        queue.sync {
            if cachedFrameTimestamp == frame.timestamp {
                return ModelFrameDetections(
                    status: .success,
                    frameTimestamp: cachedFrameTimestamp,
                    imageWidth: cachedFrameWidth,
                    imageHeight: cachedFrameHeight,
                    detections: cachedDetections
                )
            }

            do {
                let detections = try backend.predictDetections(frame: frame).map { detection in
                    var labeledDetection = detection
                    labeledDetection.labelName = labelLookup?.labelName(for: detection.classId)
                    return labeledDetection
                }
                cachedFrameTimestamp = frame.timestamp
                cachedFrameWidth = Int32(frame.width)
                cachedFrameHeight = Int32(frame.height)
                cachedDetections = detections
                return ModelFrameDetections(
                    status: .success,
                    frameTimestamp: frame.timestamp,
                    imageWidth: Int32(frame.width),
                    imageHeight: Int32(frame.height),
                    detections: detections
                )
            } catch let error as ModelRunnerError {
                return ModelFrameDetections(
                    status: error.status,
                    frameTimestamp: frame.timestamp,
                    imageWidth: Int32(frame.width),
                    imageHeight: Int32(frame.height),
                    detections: []
                )
            } catch {
                return ModelFrameDetections(
                    status: .inferenceFailed,
                    frameTimestamp: frame.timestamp,
                    imageWidth: Int32(frame.width),
                    imageHeight: Int32(frame.height),
                    detections: []
                )
            }
        }
    }
}

final class ModelRunner {
    static let shared = ModelRunner()

    private let lock = NSLock()
    private var nextModelId: Int32 = 1
    private var bundleBaseURL: URL?
    private var loadedObjectDetectionModels: [Int32: LoadedObjectDetectionModel] = [:]

    private init() {}

    func beginRun(bundleBaseURL: URL) {
        lock.lock()
        self.bundleBaseURL = bundleBaseURL
        loadedObjectDetectionModels.removeAll()
        nextModelId = 1
        lock.unlock()
    }

    func endRun() {
        lock.lock()
        loadedObjectDetectionModels.removeAll()
        bundleBaseURL = nil
        nextModelId = 1
        lock.unlock()
    }

    func hasActiveModels() -> Bool {
        lock.lock()
        let hasModels = !loadedObjectDetectionModels.isEmpty
        lock.unlock()
        return hasModels
    }

    func openModel(manifestPath: String) -> (status: ModelRunnerStatus, modelId: Int32) {
        let trimmedPath = manifestPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return (.badRequest, 0)
        }

        guard let manifestURL = resolveAssetURL(for: trimmedPath) else {
            WasmManager.shared.appendLogLine("[ml] invalid manifest path: \(trimmedPath)")
            return (.notFound, 0)
        }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            WasmManager.shared.appendLogLine("[ml] manifest not found: \(manifestURL.path)")
            return (.notFound, 0)
        }

        do {
            let manifestData = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            let manifest = try decoder.decode(ModelBundleManifest.self, from: manifestData)
            try validate(manifest: manifest)

            guard let modelURL = resolvedRelativeURL(
                path: manifest.modelFile,
                relativeTo: manifestURL.deletingLastPathComponent()
            ) else {
                throw ModelRunnerError.invalidManifest("invalid model_file in \(manifestURL.lastPathComponent)")
            }
            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                throw ModelRunnerError.invalidManifest("model not found at \(modelURL.path)")
            }

            let labelLookup = try loadLabelLookup(
                manifest: manifest,
                manifestURL: manifestURL
            )
            let backend = try makeObjectDetectionBackend(
                manifest: manifest,
                modelURL: modelURL
            )

            lock.lock()
            let modelId = nextModelId
            nextModelId += 1
            loadedObjectDetectionModels[modelId] = LoadedObjectDetectionModel(
                id: modelId,
                manifestURL: manifestURL,
                manifest: manifest,
                backend: backend,
                labelLookup: labelLookup
            )
            lock.unlock()

            WasmManager.shared.appendLogLine("[ml] loaded model \(manifest.name) id=\(modelId)")
            return (.success, modelId)
        } catch let error as ModelRunnerError {
            WasmManager.shared.appendLogLine("[ml] open failed: \(error.localizedDescription)")
            return (error.status, 0)
        } catch {
            WasmManager.shared.appendLogLine("[ml] open failed: \(error.localizedDescription)")
            return (.invalidManifest, 0)
        }
    }

    func runLatestCameraFrame(modelId: Int32) -> ModelFrameDetections {
        let model: LoadedObjectDetectionModel?
        lock.lock()
        model = loadedObjectDetectionModels[modelId]
        lock.unlock()

        guard let model else {
            return ModelFrameDetections(
                status: .invalidModel,
                frameTimestamp: 0,
                imageWidth: 0,
                imageHeight: 0,
                detections: []
            )
        }

        guard let frame = AVManager.shared.latestCameraFrameSnapshot() else {
            return ModelFrameDetections(
                status: .noFrameAvailable,
                frameTimestamp: 0,
                imageWidth: 0,
                imageHeight: 0,
                detections: []
            )
        }

        return model.runLatestFrame(frame)
    }

    func runActiveModels(frame: CameraImageFrame) -> [ActiveModelFrameDetections] {
        let models: [LoadedObjectDetectionModel]
        lock.lock()
        models = loadedObjectDetectionModels.values.sorted { $0.id < $1.id }
        lock.unlock()

        return models.map { model in
            ActiveModelFrameDetections(
                modelId: model.id,
                modelName: model.manifest.name,
                manifestName: model.manifestURL.lastPathComponent,
                result: model.runLatestFrame(frame)
            )
        }
    }

    func closeModel(modelId: Int32) -> ModelRunnerStatus {
        lock.lock()
        let removed = loadedObjectDetectionModels.removeValue(forKey: modelId)
        lock.unlock()
        return removed == nil ? .invalidModel : .success
    }

    private func resolveAssetURL(for path: String) -> URL? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        if let runtimeURL = WasmManager.shared.runtimeAssetURL(for: path) {
            return runtimeURL
        }
        lock.lock()
        let baseURL = bundleBaseURL
        lock.unlock()
        return baseURL?.appendingPathComponent(path, isDirectory: false)
    }

    private func validate(manifest: ModelBundleManifest) throws {
        guard manifest.task == "object_detection" else {
            throw ModelRunnerError.unsupportedTask("unsupported task \(manifest.task)")
        }
        guard manifest.input.width > 0, manifest.input.height > 0, manifest.input.channels == 3 else {
            throw ModelRunnerError.invalidManifest("only 3-channel RGB inputs are supported")
        }
        guard manifest.output.elementsPerDetection == 6 else {
            throw ModelRunnerError.invalidManifest("output.elements_per_detection must be 6")
        }
        guard manifest.output.maxDetections > 0 else {
            throw ModelRunnerError.invalidManifest("output.max_detections must be positive")
        }
        guard manifest.input.resizeMode == "stretch" else {
            throw ModelRunnerError.invalidManifest("only input.resize_mode=stretch is supported")
        }
    }

    private func makeObjectDetectionBackend(
        manifest: ModelBundleManifest,
        modelURL: URL
    ) throws -> ObjectDetectionBackend {
        switch manifest.backend {
        case "executorch":
            return try ExecuTorchObjectDetectionBackend(manifest: manifest, modelURL: modelURL)
        default:
            throw ModelRunnerError.unsupportedBackend("unsupported backend \(manifest.backend)")
        }
    }

    private func resolvedRelativeURL(path: String, relativeTo baseURL: URL) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }
        if trimmedPath.hasPrefix("/") {
            return URL(fileURLWithPath: trimmedPath, isDirectory: false)
        }
        return baseURL.appendingPathComponent(trimmedPath, isDirectory: false)
    }

    private func loadLabelLookup(
        manifest: ModelBundleManifest,
        manifestURL: URL
    ) throws -> DetectionLabelLookup? {
        guard let labelsPath = manifest.labelsFile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !labelsPath.isEmpty else {
            return nil
        }

        guard let labelsURL = resolvedRelativeURL(
            path: labelsPath,
            relativeTo: manifestURL.deletingLastPathComponent()
        ) else {
            throw ModelRunnerError.invalidManifest("invalid labels_file in \(manifestURL.lastPathComponent)")
        }
        guard FileManager.default.fileExists(atPath: labelsURL.path) else {
            throw ModelRunnerError.invalidManifest("labels file not found at \(labelsURL.path)")
        }

        let data = try Data(contentsOf: labelsURL)
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) {
            if let labels = jsonObject as? [String] {
                return DetectionLabelLookup(
                    explicitLabels: [:],
                    indexedLabels: labels,
                    indexBase: inferLabelIndexBase(labels)
                )
            }
            if let rawMap = jsonObject as? [String: Any] {
                var explicitLabels: [Int32: String] = [:]
                for (key, value) in rawMap {
                    guard let classId = Int32(key), let label = value as? String else {
                        continue
                    }
                    explicitLabels[classId] = label
                }
                if !explicitLabels.isEmpty {
                    return DetectionLabelLookup(explicitLabels: explicitLabels, indexedLabels: [], indexBase: 0)
                }
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw ModelRunnerError.invalidManifest("labels file must be utf-8 text or JSON")
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var explicitLabels: [Int32: String] = [:]
        var indexedLabels: [String] = []
        var sawExplicitMapping = false

        for line in lines {
            if let separatorIndex = line.firstIndex(where: { $0 == "," || $0 == "\t" || $0 == ":" }) {
                let keyPart = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let valuePart = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let classId = Int32(keyPart), !valuePart.isEmpty {
                    explicitLabels[classId] = valuePart
                    sawExplicitMapping = true
                    continue
                }
            }
            indexedLabels.append(line)
        }

        if sawExplicitMapping {
            return DetectionLabelLookup(
                explicitLabels: explicitLabels,
                indexedLabels: indexedLabels,
                indexBase: inferLabelIndexBase(indexedLabels)
            )
        }

        if !indexedLabels.isEmpty {
            return DetectionLabelLookup(
                explicitLabels: [:],
                indexedLabels: indexedLabels,
                indexBase: inferLabelIndexBase(indexedLabels)
            )
        }

        return nil
    }

    private func inferLabelIndexBase(_ labels: [String]) -> Int32 {
        guard let firstLabel = labels.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return 1
        }
        if firstLabel == "__background__" || firstLabel == "background" || firstLabel == "bg" {
            return 0
        }
        return 1
    }
}

#if canImport(ExecuTorch)
private final class ExecuTorchObjectDetectionBackend: ObjectDetectionBackend {
    private let manifest: ModelBundleManifest
    private let module: Module

    init(manifest: ModelBundleManifest, modelURL: URL) throws {
        self.manifest = manifest
        self.module = Module(filePath: modelURL.path)
        do {
            try module.load(manifest.method)
        } catch {
            throw ModelRunnerError.runtimeUnavailable("failed to load ExecuTorch method \(manifest.method): \(error.localizedDescription)")
        }
    }

    func predictDetections(frame: CameraImageFrame) throws -> [ModelDetection] {
        let inputTensorValues = preprocess(frame: frame, config: manifest.input)
        let inputTensor = Tensor<Float>(
            inputTensorValues,
            shape: [1, 3, manifest.input.height, manifest.input.width]
        )

        let outputTensor: Tensor<Float>
        do {
            outputTensor = try Tensor<Float>(module.forward(inputTensor))
        } catch {
            throw ModelRunnerError.inferenceFailed("ExecuTorch forward failed: \(error.localizedDescription)")
        }

        let scalars: [Float]
        do {
            scalars = try outputTensor.scalars()
        } catch {
            throw ModelRunnerError.inferenceFailed("failed to read model outputs: \(error.localizedDescription)")
        }

        return parseDetections(
            scalars: scalars,
            output: manifest.output,
            scoreThreshold: manifest.scoreThreshold
        )
    }

    private func parseDetections(
        scalars: [Float],
        output: ModelBundleManifest.OutputConfig,
        scoreThreshold: Float
    ) -> [ModelDetection] {
        let stride = output.elementsPerDetection
        guard stride > 0 else {
            return []
        }

        let maxDetections = min(output.maxDetections, 32)
        let rowCount = min(scalars.count / stride, maxDetections)
        var detections: [ModelDetection] = []
        detections.reserveCapacity(rowCount)

        for row in 0..<rowCount {
            let base = row * stride
            let classId = Int32(scalars[base + 0].rounded())
            let score = scalars[base + 1]
            if score < scoreThreshold {
                continue
            }
            detections.append(
                ModelDetection(
                    classId: classId,
                    score: score,
                    xMin: scalars[base + 2],
                    yMin: scalars[base + 3],
                    xMax: scalars[base + 4],
                    yMax: scalars[base + 5]
                )
            )
        }
        return detections
    }

    private func preprocess(
        frame: CameraImageFrame,
        config: ModelBundleManifest.InputConfig
    ) -> [Float] {
        let width = config.width
        let height = config.height
        let planeSize = width * height
        var chw = [Float](repeating: 0, count: planeSize * 3)

        let mean = normalizedMeans(values: config.mean)
        let std = normalizedStds(values: config.std)

        for y in 0..<height {
            let srcY = min(frame.height - 1, (y * frame.height) / height)
            for x in 0..<width {
                let srcX = min(frame.width - 1, (x * frame.width) / width)
                let srcBase = ((srcY * frame.width) + srcX) * 3
                let dstIndex = (y * width) + x

                let r = (Float(frame.rgbBytes[srcBase + 0]) * config.valueScale - mean[0]) / std[0]
                let g = (Float(frame.rgbBytes[srcBase + 1]) * config.valueScale - mean[1]) / std[1]
                let b = (Float(frame.rgbBytes[srcBase + 2]) * config.valueScale - mean[2]) / std[2]

                chw[dstIndex] = r
                chw[planeSize + dstIndex] = g
                chw[(2 * planeSize) + dstIndex] = b
            }
        }

        return chw
    }

    private func normalizedMeans(values: [Float]) -> [Float] {
        if values.count >= 3 {
            return [values[0], values[1], values[2]]
        }
        return [0, 0, 0]
    }

    private func normalizedStds(values: [Float]) -> [Float] {
        if values.count >= 3 {
            return [
                max(values[0], 1e-6),
                max(values[1], 1e-6),
                max(values[2], 1e-6),
            ]
        }
        return [1, 1, 1]
    }
}
#else
private final class ExecuTorchObjectDetectionBackend: ObjectDetectionBackend {
    init(manifest: ModelBundleManifest, modelURL: URL) throws {
        throw ModelRunnerError.runtimeUnavailable(
            "ExecuTorch package is not linked; add the official ExecuTorch Swift package before loading \(manifest.name)"
        )
    }

    func predictDetections(frame: CameraImageFrame) throws -> [ModelDetection] {
        throw ModelRunnerError.runtimeUnavailable("ExecuTorch package is not linked")
    }
}
#endif
