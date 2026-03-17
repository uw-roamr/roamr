//
//  ModelRunner.swift
//  roamr
//
//  Dynamic model loading and camera-frame inference for WASM policies.
//

import Foundation
import Accelerate

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
    var preprocessMs: Double = 0
    var forwardMs: Double = 0
    var outputDecodeMs: Double = 0
}

struct ActiveModelFrameDetections {
    var modelId: Int32
    var modelName: String
    var manifestName: String
    var result: ModelFrameDetections
}

struct ActiveInferenceStats {
    var submittedCount: Int
    var droppedCount: Int
    var completedCount: Int
    var pendingCount: Int
    var isRunning: Bool
    var latencyMs: Double
    var preprocessMs: Double
    var forwardMs: Double
    var outputDecodeMs: Double
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
    func predict(frame: CameraImageFrame) throws -> PredictionResult
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
                let prediction = try backend.predict(frame: frame)
                let detections = prediction.detections.map { detection in
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
                    detections: detections,
                    preprocessMs: prediction.preprocessMs,
                    forwardMs: prediction.forwardMs,
                    outputDecodeMs: prediction.outputDecodeMs
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

    private struct ActiveInferenceState {
        var generation: UInt64 = 0
        var pendingFrame: CameraImageFrame?
        var isRunning = false
        var submittedCount = 0
        var droppedCount = 0
        var completedCount = 0
        var lastLoggedCompletedCount = 0
        var lastLogTime: TimeInterval = 0
    }

    private let lock = NSLock()
    private let activeInferenceStateQueue = DispatchQueue(
        label: "com.roamr.modelrunner.activeInference.state",
        qos: .userInitiated
    )
    private let activeInferenceExecutionQueue = DispatchQueue(
        label: "com.roamr.modelrunner.activeInference.execution",
        qos: .userInitiated
    )
    private var nextModelId: Int32 = 1
    private var bundleBaseURL: URL?
    private var loadedObjectDetectionModels: [Int32: LoadedObjectDetectionModel] = [:]
    private var activeInferenceState = ActiveInferenceState()

    private init() {}

    func beginRun(bundleBaseURL: URL) {
        lock.lock()
        self.bundleBaseURL = bundleBaseURL
        loadedObjectDetectionModels.removeAll()
        nextModelId = 1
        lock.unlock()
        resetActiveInferenceState()
    }

    func endRun() {
        lock.lock()
        loadedObjectDetectionModels.removeAll()
        bundleBaseURL = nil
        nextModelId = 1
        lock.unlock()
        resetActiveInferenceState()
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

    func submitActiveModels(
        frame: CameraImageFrame,
        resultHandler: @escaping (CameraImageFrame, [ActiveModelFrameDetections], ActiveInferenceStats) -> Void
    ) {
        activeInferenceStateQueue.async {
            self.activeInferenceState.submittedCount += 1
            if self.activeInferenceState.pendingFrame != nil {
                self.activeInferenceState.droppedCount += 1
            }
            self.activeInferenceState.pendingFrame = frame

            guard !self.activeInferenceState.isRunning else {
                return
            }

            self.activeInferenceState.isRunning = true
            let generation = self.activeInferenceState.generation
            self.startNextActiveInference(generation: generation, resultHandler: resultHandler)
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

    private func resetActiveInferenceState() {
        activeInferenceStateQueue.sync {
            activeInferenceState.generation &+= 1
            activeInferenceState.pendingFrame = nil
            activeInferenceState.isRunning = false
            activeInferenceState.submittedCount = 0
            activeInferenceState.droppedCount = 0
            activeInferenceState.completedCount = 0
            activeInferenceState.lastLoggedCompletedCount = 0
            activeInferenceState.lastLogTime = 0
        }
    }

    private func startNextActiveInference(
        generation: UInt64,
        resultHandler: @escaping (CameraImageFrame, [ActiveModelFrameDetections], ActiveInferenceStats) -> Void
    ) {
        activeInferenceStateQueue.async {
            guard self.activeInferenceState.generation == generation else {
                return
            }

            guard let frame = self.activeInferenceState.pendingFrame else {
                self.activeInferenceState.isRunning = false
                return
            }

            self.activeInferenceState.pendingFrame = nil

            self.activeInferenceExecutionQueue.async {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let results = self.runActiveModels(frame: frame)
                let latencyMs = max(0, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)
                let preprocessMs = results.map(\.result.preprocessMs).max() ?? 0
                let forwardMs = results.map(\.result.forwardMs).max() ?? 0
                let outputDecodeMs = results.map(\.result.outputDecodeMs).max() ?? 0

                self.activeInferenceStateQueue.async {
                    guard self.activeInferenceState.generation == generation else {
                        return
                    }

                    self.activeInferenceState.completedCount += 1
                    let stats = ActiveInferenceStats(
                        submittedCount: self.activeInferenceState.submittedCount,
                        droppedCount: self.activeInferenceState.droppedCount,
                        completedCount: self.activeInferenceState.completedCount,
                        pendingCount: self.activeInferenceState.pendingFrame == nil ? 0 : 1,
                        isRunning: true,
                        latencyMs: latencyMs,
                        preprocessMs: preprocessMs,
                        forwardMs: forwardMs,
                        outputDecodeMs: outputDecodeMs
                    )

                    self.maybeLogActiveInferenceStats(stats)
                    resultHandler(frame, results, stats)
                    self.startNextActiveInference(generation: generation, resultHandler: resultHandler)
                }
            }
        }
    }

    private func maybeLogActiveInferenceStats(_ stats: ActiveInferenceStats) {
        let now = CFAbsoluteTimeGetCurrent()
        let shouldLogForDrop = stats.droppedCount > 0 && stats.droppedCount % 10 == 0
        let shouldLogForCompletion = stats.completedCount - activeInferenceState.lastLoggedCompletedCount >= 30
        let shouldLogForTime = now - activeInferenceState.lastLogTime >= 5.0
        guard shouldLogForDrop || shouldLogForCompletion || shouldLogForTime else {
            return
        }

        activeInferenceState.lastLoggedCompletedCount = stats.completedCount
        activeInferenceState.lastLogTime = now
        print(
            "[ml] async inference submitted=\(stats.submittedCount) completed=\(stats.completedCount) " +
            "dropped=\(stats.droppedCount) pending=\(stats.pendingCount) latency_ms=\(String(format: "%.1f", stats.latencyMs)) " +
            "pre_ms=\(String(format: "%.1f", stats.preprocessMs)) " +
            "fwd_ms=\(String(format: "%.1f", stats.forwardMs)) " +
            "out_ms=\(String(format: "%.1f", stats.outputDecodeMs))"
        )
    }
}

#if canImport(ExecuTorch)
private struct PreprocessResult {
    let chw: [Float]
    let preprocessMs: Double
}

private struct PredictionResult {
    let detections: [ModelDetection]
    let preprocessMs: Double
    let forwardMs: Double
    let outputDecodeMs: Double
}

private struct FloatPlaneNormalization {
    let scale: Float
    let bias: Float
}

private final class ExecuTorchObjectDetectionBackend: ObjectDetectionBackend {
    private let manifest: ModelBundleManifest
    private let module: Module
    private let inputWidth: Int
    private let inputHeight: Int
    private let planeSize: Int
    private let usesFastNormalizationPath: Bool
    private let normalization: [FloatPlaneNormalization]

    private var sourcePlanarRed8: [UInt8] = []
    private var sourcePlanarGreen8: [UInt8] = []
    private var sourcePlanarBlue8: [UInt8] = []
    private var planarRed8: [UInt8] = []
    private var planarGreen8: [UInt8] = []
    private var planarBlue8: [UInt8] = []
    private var planarRedF: [Float] = []
    private var planarGreenF: [Float] = []
    private var planarBlueF: [Float] = []
    private var chwBuffer: [Float] = []

    init(manifest: ModelBundleManifest, modelURL: URL) throws {
        self.manifest = manifest
        self.module = Module(filePath: modelURL.path)
        self.inputWidth = manifest.input.width
        self.inputHeight = manifest.input.height
        self.planeSize = manifest.input.width * manifest.input.height
        let means = ExecuTorchObjectDetectionBackend.normalizedMeans(values: manifest.input.mean)
        let stds = ExecuTorchObjectDetectionBackend.normalizedStds(values: manifest.input.std)
        self.usesFastNormalizationPath =
            abs(manifest.input.valueScale - (1.0 / 255.0)) < 1e-8 &&
            means == [0, 0, 0] &&
            stds == [1, 1, 1]
        self.normalization = zip(means, stds).map { mean, std in
            FloatPlaneNormalization(
                scale: manifest.input.valueScale / std,
                bias: -mean / std
            )
        }
        self.sourcePlanarRed8 = []
        self.sourcePlanarGreen8 = []
        self.sourcePlanarBlue8 = []
        self.planarRed8 = [UInt8](repeating: 0, count: planeSize)
        self.planarGreen8 = [UInt8](repeating: 0, count: planeSize)
        self.planarBlue8 = [UInt8](repeating: 0, count: planeSize)
        self.planarRedF = [Float](repeating: 0, count: planeSize)
        self.planarGreenF = [Float](repeating: 0, count: planeSize)
        self.planarBlueF = [Float](repeating: 0, count: planeSize)
        self.chwBuffer = [Float](repeating: 0, count: planeSize * 3)
        do {
            try module.load(manifest.method)
        } catch {
            throw ModelRunnerError.runtimeUnavailable("failed to load ExecuTorch method \(manifest.method): \(error.localizedDescription)")
        }
    }

    func predictDetections(frame: CameraImageFrame) throws -> [ModelDetection] {
        let prediction = try predict(frame: frame)
        return prediction.detections
    }

    func predict(frame: CameraImageFrame) throws -> PredictionResult {
        let preprocessResult = try preprocess(frame: frame, config: manifest.input)
        let inputTensor = Tensor<Float>(
            preprocessResult.chw,
            shape: [1, 3, manifest.input.height, manifest.input.width]
        )

        let outputTensor: Tensor<Float>
        let forwardStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            outputTensor = try Tensor<Float>(module.forward(inputTensor))
        } catch {
            throw ModelRunnerError.inferenceFailed("ExecuTorch forward failed: \(error.localizedDescription)")
        }
        let forwardMs = max(0, (CFAbsoluteTimeGetCurrent() - forwardStartedAt) * 1000.0)

        let scalars: [Float]
        let outputDecodeStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            scalars = try outputTensor.scalars()
        } catch {
            throw ModelRunnerError.inferenceFailed("failed to read model outputs: \(error.localizedDescription)")
        }
        let outputDecodeMs = max(0, (CFAbsoluteTimeGetCurrent() - outputDecodeStartedAt) * 1000.0)

        return PredictionResult(
            detections: parseDetections(
                scalars: scalars,
                output: manifest.output,
                scoreThreshold: manifest.scoreThreshold
            ),
            preprocessMs: preprocessResult.preprocessMs,
            forwardMs: forwardMs,
            outputDecodeMs: outputDecodeMs
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
    ) throws -> PreprocessResult {
        guard frame.width > 0, frame.height > 0, frame.channels == 3 else {
            throw ModelRunnerError.inferenceFailed("invalid camera frame for preprocess")
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        try splitSourceRGBToPlanar(frame: frame)
        try resizePlanar8(
            source: &sourcePlanarRed8,
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            destination: &planarRed8
        )
        try resizePlanar8(
            source: &sourcePlanarGreen8,
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            destination: &planarGreen8
        )
        try resizePlanar8(
            source: &sourcePlanarBlue8,
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            destination: &planarBlue8
        )

        if usesFastNormalizationPath {
            try convertFastPlanar8ToUnitFloatCHW()
        } else {
            try convertGenericPlanar8ToFloatCHW()
        }

        return PreprocessResult(
            chw: chwBuffer,
            preprocessMs: max(0, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)
        )
    }

    private func ensureSourcePlanarCapacity(pixelCount: Int) {
        if sourcePlanarRed8.count != pixelCount {
            sourcePlanarRed8 = [UInt8](repeating: 0, count: pixelCount)
            sourcePlanarGreen8 = [UInt8](repeating: 0, count: pixelCount)
            sourcePlanarBlue8 = [UInt8](repeating: 0, count: pixelCount)
        }
    }

    private func splitSourceRGBToPlanar(frame: CameraImageFrame) throws {
        let sourcePixelCount = frame.width * frame.height
        ensureSourcePlanarCapacity(pixelCount: sourcePixelCount)

        var sourceBytes = frame.rgbBytes
        let error = sourceBytes.withUnsafeMutableBytes { srcRaw in
            sourcePlanarRed8.withUnsafeMutableBytes { redRaw in
                sourcePlanarGreen8.withUnsafeMutableBytes { greenRaw in
                    sourcePlanarBlue8.withUnsafeMutableBytes { blueRaw in
                        guard let srcBaseAddress = srcRaw.baseAddress,
                              let redBaseAddress = redRaw.baseAddress,
                              let greenBaseAddress = greenRaw.baseAddress,
                              let blueBaseAddress = blueRaw.baseAddress else {
                            return kvImageNullPointerArgument
                        }

                        var srcBuffer = vImage_Buffer(
                            data: srcBaseAddress,
                            height: vImagePixelCount(frame.height),
                            width: vImagePixelCount(frame.width),
                            rowBytes: frame.width * 3
                        )
                        var redBuffer = vImage_Buffer(
                            data: redBaseAddress,
                            height: vImagePixelCount(frame.height),
                            width: vImagePixelCount(frame.width),
                            rowBytes: frame.width
                        )
                        var greenBuffer = vImage_Buffer(
                            data: greenBaseAddress,
                            height: vImagePixelCount(frame.height),
                            width: vImagePixelCount(frame.width),
                            rowBytes: frame.width
                        )
                        var blueBuffer = vImage_Buffer(
                            data: blueBaseAddress,
                            height: vImagePixelCount(frame.height),
                            width: vImagePixelCount(frame.width),
                            rowBytes: frame.width
                        )
                        return vImageConvert_RGB888toPlanar8(
                            &srcBuffer,
                            &redBuffer,
                            &greenBuffer,
                            &blueBuffer,
                            vImage_Flags(kvImageNoFlags)
                        )
                    }
                }
            }
        }
        guard error == kvImageNoError else {
            throw ModelRunnerError.inferenceFailed("vImageConvert_RGB888toPlanar8 failed: \(error)")
        }
    }

    private func resizePlanar8(
        source: inout [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        destination: inout [UInt8]
    ) throws {
        let error = source.withUnsafeMutableBytes { srcRaw in
            destination.withUnsafeMutableBytes { dstRaw in
                guard let srcBaseAddress = srcRaw.baseAddress,
                      let dstBaseAddress = dstRaw.baseAddress else {
                    return kvImageNullPointerArgument
                }

                var srcBuffer = vImage_Buffer(
                    data: srcBaseAddress,
                    height: vImagePixelCount(sourceHeight),
                    width: vImagePixelCount(sourceWidth),
                    rowBytes: sourceWidth
                )
                var dstBuffer = vImage_Buffer(
                    data: dstBaseAddress,
                    height: vImagePixelCount(inputHeight),
                    width: vImagePixelCount(inputWidth),
                    rowBytes: inputWidth
                )
                return vImageScale_Planar8(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        guard error == kvImageNoError else {
            throw ModelRunnerError.inferenceFailed("vImageScale_Planar8 failed: \(error)")
        }
    }

    private func convertFastPlanar8ToUnitFloatCHW() throws {
        try convertPlanar8(
            source: &planarRed8,
            destination: &planarRedF,
            maxFloat: 1.0,
            minFloat: 0.0
        )
        try convertPlanar8(
            source: &planarGreen8,
            destination: &planarGreenF,
            maxFloat: 1.0,
            minFloat: 0.0
        )
        try convertPlanar8(
            source: &planarBlue8,
            destination: &planarBlueF,
            maxFloat: 1.0,
            minFloat: 0.0
        )

        chwBuffer.withUnsafeMutableBufferPointer { chw in
            guard let chwBase = chw.baseAddress else { return }
            planarRedF.withUnsafeBufferPointer { red in
                planarGreenF.withUnsafeBufferPointer { green in
                    planarBlueF.withUnsafeBufferPointer { blue in
                        guard let redBase = red.baseAddress,
                              let greenBase = green.baseAddress,
                              let blueBase = blue.baseAddress else {
                            return
                        }
                        chwBase.initialize(from: redBase, count: planeSize)
                        (chwBase + planeSize).initialize(from: greenBase, count: planeSize)
                        (chwBase + (2 * planeSize)).initialize(from: blueBase, count: planeSize)
                    }
                }
            }
        }
    }

    private func convertGenericPlanar8ToFloatCHW() throws {
        try convertPlanar8(
            source: &planarRed8,
            destination: &planarRedF,
            maxFloat: normalization[0].scale * 255.0 + normalization[0].bias,
            minFloat: normalization[0].bias
        )
        try convertPlanar8(
            source: &planarGreen8,
            destination: &planarGreenF,
            maxFloat: normalization[1].scale * 255.0 + normalization[1].bias,
            minFloat: normalization[1].bias
        )
        try convertPlanar8(
            source: &planarBlue8,
            destination: &planarBlueF,
            maxFloat: normalization[2].scale * 255.0 + normalization[2].bias,
            minFloat: normalization[2].bias
        )

        chwBuffer.withUnsafeMutableBufferPointer { chw in
            guard let chwBase = chw.baseAddress else { return }
            planarRedF.withUnsafeBufferPointer { red in
                planarGreenF.withUnsafeBufferPointer { green in
                    planarBlueF.withUnsafeBufferPointer { blue in
                        guard let redBase = red.baseAddress,
                              let greenBase = green.baseAddress,
                              let blueBase = blue.baseAddress else {
                            return
                        }
                        chwBase.initialize(from: redBase, count: planeSize)
                        (chwBase + planeSize).initialize(from: greenBase, count: planeSize)
                        (chwBase + (2 * planeSize)).initialize(from: blueBase, count: planeSize)
                    }
                }
            }
        }
    }

    private func convertPlanar8(
        source: inout [UInt8],
        destination: inout [Float],
        maxFloat: Float,
        minFloat: Float
    ) throws {
        let error = source.withUnsafeMutableBytes { srcRaw in
            destination.withUnsafeMutableBytes { dstRaw in
                guard let srcBaseAddress = srcRaw.baseAddress,
                      let dstBaseAddress = dstRaw.baseAddress else {
                    return kvImageNullPointerArgument
                }

                var srcBuffer = vImage_Buffer(
                    data: srcBaseAddress,
                    height: vImagePixelCount(inputHeight),
                    width: vImagePixelCount(inputWidth),
                    rowBytes: inputWidth
                )
                var dstBuffer = vImage_Buffer(
                    data: dstBaseAddress,
                    height: vImagePixelCount(inputHeight),
                    width: vImagePixelCount(inputWidth),
                    rowBytes: inputWidth * MemoryLayout<Float>.size
                )
                return vImageConvert_Planar8toPlanarF(
                    &srcBuffer,
                    &dstBuffer,
                    maxFloat,
                    minFloat,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }
        guard error == kvImageNoError else {
            throw ModelRunnerError.inferenceFailed("vImageConvert_Planar8toPlanarF failed: \(error)")
        }
    }

    private static func normalizedMeans(values: [Float]) -> [Float] {
        if values.count >= 3 {
            return [values[0], values[1], values[2]]
        }
        return [0, 0, 0]
    }

    private static func normalizedStds(values: [Float]) -> [Float] {
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

    func predict(frame: CameraImageFrame) throws -> PredictionResult {
        throw ModelRunnerError.runtimeUnavailable("ExecuTorch package is not linked")
    }
}
#endif
