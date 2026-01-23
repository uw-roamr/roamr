//
//  RerunLogger.swift
//  roamr
//
//  Created by Codex on 2025-11-23.
//

import Foundation

private struct RerunPointsMessage: Codable {
    let type: String
    let timestamp: Double
    let points: [Float]
}

final class RerunWebSocketClient {
    static let shared = RerunWebSocketClient()

    private static let serverURLDefaultsKey = "rerun_ws_server_url"
    static let defaultServerURLString = "ws://172.20.10.2:9877"
    private let queue = DispatchQueue(label: "com.roamr.rerun.ws")
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var isConnected = false

    var serverURLString = RerunWebSocketClient.defaultServerURLString

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey),
           !stored.isEmpty {
            serverURLString = normalizeURLString(stored)
        }
    }

    func logPoints(timestamp: Double, points: [Float]) {
        guard !points.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connectIfNeeded()

            let message = RerunPointsMessage(type: "points3d", timestamp: timestamp, points: points)
            guard let payload = try? JSONEncoder().encode(message),
                  let payloadString = String(data: payload, encoding: .utf8) else {
                return
            }

            self.task?.send(.string(payloadString)) { error in
                if let error = error {
                    print("Rerun websocket send error: \(error)")
                    self.isConnected = false
                }
            }
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

    if let nativeEnd = nativeEnd {
        let baseAddr = UInt(bitPattern: basePtr)
        let endAddr = UInt(bitPattern: nativeEnd)
        if baseAddr + UInt(pointsSizeOffset + pointsSizeBytes) > endAddr {
            return
        }
    }

    let timestamp = basePtr.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee }
    let pointsSizeValue = basePtr.advanced(by: pointsSizeOffset)
        .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

    let floatsCount = max(0, min(Int(pointsSizeValue), pointsMaxCount))
    if floatsCount < 3 { return }

    if let nativeEnd = nativeEnd {
        let baseAddr = UInt(bitPattern: basePtr)
        let endAddr = UInt(bitPattern: nativeEnd)
        let pointsEnd = baseAddr + UInt(pointsOffset + floatsCount * MemoryLayout<Float32>.size)
        if pointsEnd > endAddr {
            return
        }
    }

    let totalPoints = floatsCount / 3
    let maxPointsToSend = 5000
    let stride = max(1, totalPoints / maxPointsToSend)
    var sampled: [Float] = []
    sampled.reserveCapacity(min(totalPoints, maxPointsToSend) * 3)

    let pointsPtr = basePtr.advanced(by: pointsOffset).withMemoryRebound(to: Float32.self, capacity: floatsCount) { $0 }
    var i = 0
    while i < totalPoints {
        let idx = i * 3
        sampled.append(pointsPtr[idx])
        sampled.append(pointsPtr[idx + 1])
        sampled.append(pointsPtr[idx + 2])
        i += stride
    }

    RerunWebSocketClient.shared.logPoints(timestamp: timestamp, points: sampled)
}
