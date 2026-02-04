import Foundation

private enum RerunMessage: Encodable {
    case points(timestamp: Double, points: [Float], colors: [UInt8]?)
    case pose(timestamp: Double, quaternion: [Double])
    case motors(timestamp: Double, left: Int, right: Int, holdMs: Int)

    enum CodingKeys: String, CodingKey { case type, timestamp, points, colors, quaternion, left, right, hold_ms }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .points(timestamp, points, colors):
            try container.encode("points3d", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(points, forKey: .points)
            try container.encodeIfPresent(colors, forKey: .colors)
        case let .pose(timestamp, quaternion):
            try container.encode("pose", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(quaternion, forKey: .quaternion)
        case let .motors(timestamp, left, right, holdMs):
            try container.encode("motors", forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)
            try container.encode(holdMs, forKey: .hold_ms)
        }
    }
}

final class RerunWebSocketClient {
    static let shared = RerunWebSocketClient()

    private static let serverURLDefaultsKey = "rerun_ws_server_url"
    static let defaultServerURLString = "ws://172.20.10.2:9877"
    private let queue = DispatchQueue(label: "com.roamr.rerun.ws")
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var isConnected = false

    private let encoder = JSONEncoder()

    var serverURLString = RerunWebSocketClient.defaultServerURLString

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey),
           !stored.isEmpty {
            serverURLString = normalizeURLString(stored)
        }
    }

    func logPoints(timestamp: Double, points: [Float], colors: [UInt8]?) {
        guard !points.isEmpty else { return }
        enqueue(.points(timestamp: timestamp, points: points, colors: colors))
    }

    func logPose(timestamp: Double, quaternion: [Double]) {
        guard quaternion.count == 4 else { return }
        enqueue(.pose(timestamp: timestamp, quaternion: quaternion))
    }

    func logMotors(timestamp: Double, left: Int, right: Int, holdMs: Int) {
        enqueue(.motors(timestamp: timestamp, left: left, right: right, holdMs: holdMs))
    }

    private func enqueue(_ message: RerunMessage) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connectIfNeeded()
            self.send(message)
        }
    }

    private func connectIfNeeded() {
        if isConnected { return }
        let normalized = normalizeURLString(serverURLString)
        serverURLString = normalized
        guard let url = URL(string: normalized) else {
            print("Invalid rerun websocket URL: \(serverURLString)")
            return
        }

        print("Rerun websocket connecting to: \(serverURLString)")
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        isConnected = true
        listen()
    }

    private func send(_ message: RerunMessage) {
        guard let task = task else { return }
        guard let payload = try? encoder.encode(message),
              let payloadString = String(data: payload, encoding: .utf8) else {
            return
        }

        task.send(.string(payloadString)) { [weak self] error in
            if let error = error {
                print("Rerun websocket send error: \(error)")
                self?.isConnected = false
            }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.listen()
            case .failure(let error):
                print("Rerun websocket receive error: \(error)")
                self.isConnected = false
            }
        }
    }
}

extension RerunWebSocketClient {
    func updateServerURL(_ url: String) {
        queue.async {
            let normalized = self.normalizeURLString(url)
            guard normalized != self.serverURLString else { return }

            self.serverURLString = normalized
            UserDefaults.standard.set(normalized, forKey: Self.serverURLDefaultsKey)

            if self.isConnected {
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.isConnected = false
            }
        }
    }
}

private extension RerunWebSocketClient {
    func normalizeURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.hasPrefix("http://") {
            return "ws://\(trimmed.dropFirst("http://".count))"
        }
        if trimmed.hasPrefix("https://") {
            return "wss://\(trimmed.dropFirst("https://".count))"
        }
        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return trimmed
        }
        return "ws://\(trimmed)"
    }
}

func rerun_log_points_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let exec_env = exec_env, let ptr = ptr else { return }

    let basePtr = ptr.assumingMemoryBound(to: UInt8.self)
    guard let moduleInst = wasm_runtime_get_module_inst(exec_env) else {
        return
    }

    var nativeStart: UnsafeMutablePointer<UInt8>?
    var nativeEnd: UnsafeMutablePointer<UInt8>?
    guard wasm_runtime_get_native_addr_range(moduleInst, basePtr, &nativeStart, &nativeEnd) else {
        return
    }

    let pointsOffset = MemoryLayout<Double>.size
    let pointsMaxCount = LidarCameraConstants.maxPointsSize
    let pointsByteCount = pointsMaxCount * MemoryLayout<Float32>.size
    let pointsSizeOffset = pointsOffset + pointsByteCount
    let pointsSizeBytes = MemoryLayout<Int32>.size

    let colorsOffset = pointsSizeOffset + pointsSizeBytes
    let colorsMaxCount = LidarCameraConstants.maxColorsSize
    let colorsByteCount = colorsMaxCount * MemoryLayout<UInt8>.size
    let colorsSizeOffset = colorsOffset + colorsByteCount
    let colorsSizeBytes = MemoryLayout<Int32>.size

    if let nativeEnd = nativeEnd {
        let baseAddr = UInt(bitPattern: basePtr)
        let endAddr = UInt(bitPattern: nativeEnd)
        if baseAddr + UInt(colorsSizeOffset + colorsSizeBytes) > endAddr {
            return
        }
    }

    let timestamp = basePtr.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee }
    let pointsSizeValue = basePtr.advanced(by: pointsSizeOffset)
        .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
    let colorsSizeValue = basePtr.advanced(by: colorsSizeOffset)
        .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

    let floatsCount = max(0, min(Int(pointsSizeValue), pointsMaxCount))
    if floatsCount < 3 { return }

    if let nativeEnd = nativeEnd {
        let baseAddr = UInt(bitPattern: basePtr)
        let endAddr = UInt(bitPattern: nativeEnd)
        let pointsEnd = baseAddr + UInt(pointsOffset + floatsCount * MemoryLayout<Float32>.size)
        let colorsEnd = baseAddr + UInt(colorsOffset + max(0, min(Int(colorsSizeValue), colorsMaxCount)) * MemoryLayout<UInt8>.size)
        if pointsEnd > endAddr || colorsEnd > endAddr {
            return
        }
    }

    let totalPoints = floatsCount / 3
    let maxPointsToSend = 15000
    let targetPoints = min(totalPoints, maxPointsToSend)
    let stride = max(1, totalPoints / max(1, targetPoints))
    var sampled: [Float] = []
    sampled.reserveCapacity(targetPoints * 3)

    let pointsPtr = basePtr.advanced(by: pointsOffset).withMemoryRebound(to: Float32.self, capacity: floatsCount) { $0 }
    var i = 0
    var sampledPointCount = 0
    while i < totalPoints && sampledPointCount < targetPoints {
        let idx = i * 3
        sampled.append(pointsPtr[idx])
        sampled.append(pointsPtr[idx + 1])
        sampled.append(pointsPtr[idx + 2])
        i += stride
        sampledPointCount += 1
    }

    var sampledColors: [UInt8]? = nil
    if colorsSizeValue > 0 {
        let colorsCount = max(0, min(Int(colorsSizeValue), colorsMaxCount))
        let colorsPtr = basePtr.advanced(by: colorsOffset)
        let strideColors = stride
        var tmp: [UInt8] = []
        tmp.reserveCapacity(sampledPointCount * 3)
        var iPoint = 0
        var sampledColorCount = 0
        while iPoint < totalPoints && sampledColorCount < sampledPointCount {
            let colorIdx = iPoint * LidarCameraConstants.colorsPerPoint
            if colorIdx + 2 < colorsCount {
                tmp.append(colorsPtr[colorIdx + 0])
                tmp.append(colorsPtr[colorIdx + 1])
                tmp.append(colorsPtr[colorIdx + 2])
            }
            iPoint += strideColors
            sampledColorCount += 1
        }
        sampledColors = tmp
    }

    RerunWebSocketClient.shared.logPoints(timestamp: timestamp, points: sampled, colors: sampledColors)

    // Also ship current phone pose for synchronized visualization
    let attitude: AttitudeData
    IMUManager.shared.lock.lock()
    attitude = IMUManager.shared.currentAttitude
    IMUManager.shared.lock.unlock()
    RerunWebSocketClient.shared.logPose(
        timestamp: timestamp,
        quaternion: [attitude.quat_x, attitude.quat_y, attitude.quat_z, attitude.quat_w]
    )
}
