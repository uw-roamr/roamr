//
//  WebSocketManager.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-23.
//

import Foundation
import Network
import Combine
import CryptoKit

private enum RoamrBinaryPointCloudProtocol {
    static let magic: [UInt8] = [0x52, 0x52, 0x42, 0x31]  // "RRB1"
    static let messageTypePoints: UInt8 = 1
    static let flagsOffset = 5
    static let timestampOffset = 8
    static let pointCountOffset = 16
    static let headerSize = 20
    static let hasColorsFlag: UInt8 = 1
}

private enum RoamrBinaryMapLayerProtocol {
    static let magic: [UInt8] = [0x52, 0x52, 0x4D, 0x31]  // "RRM1"
    static let messageTypeLayer: UInt8 = 1
    static let timestampOffset = 8
    static let widthOffset = 16
    static let heightOffset = 20
    static let channelsOffset = 24
    static let layerIdOffset = 28
    static let headerSize = 32
}

private struct IncomingTeleopCommand {
    let seq: Int
    let left: Int
    let right: Int
    let holdMs: Int
}

class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()
    private static let maxRecentWasmLogs = 200
    private static let defaultBundledWasmId = "builtin:slam_main"
    private static let defaultBundledWasmName = "slam_main"

    @Published var isServerRunning = false
    @Published var localIPAddress: String = "Not available"
    @Published var serverStatus: String = "Stopped"
    @Published var lastMessage: String = ""
    @Published var connectedClients: Int = 0

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var connectionStates: [ObjectIdentifier: Bool] = [:] // Track handshake completion
    private var latestPointCloudData: Data?
    private var latestMapFrameMessage: String?
    private var latestMapLayerPayloads: [String: Data] = [:]
    private var latestMlDetectionsMessage: String?
    private var latestWasmStateMessage: String?
    private var recentWasmLogMessages: [String] = []
    private var selectedWasmTargetId: String
    private let port: NWEndpoint.Port = 8080

    // Bluetooth manager for forwarding messages
    var bluetoothManager: BluetoothManager?

    private init() {
        self.selectedWasmTargetId = Self.defaultBundledWasmId
    }

    func hasConnectedWebSocketClients() -> Bool {
        connectedClients > 0
    }

    func startServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: port)

            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isServerRunning = true
                        self?.serverStatus = "Running"
                        self?.getLocalIPAddress()
                    case .failed(let error):
                        self?.isServerRunning = false
                        self?.serverStatus = "Failed: \(error.localizedDescription)"
                    case .cancelled:
                        self?.isServerRunning = false
                        self?.serverStatus = "Stopped"
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: .main)
        } catch {
            serverStatus = "Error: \(error.localizedDescription)"
        }
    }

    func stopServer() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        connectionStates.removeAll()
        isServerRunning = false
        serverStatus = "Stopped"
        connectedClients = 0
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)
        connectedClients = connections.count
        connectionStates[ObjectIdentifier(connection)] = false // Handshake not complete

        print("🔗 New connection from \(connection.endpoint)")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✅ Connection ready, waiting for WebSocket handshake")
                self?.receiveHandshake(on: connection)
            case .failed(let error):
                print("❌ Connection failed: \(error)")
                self?.removeConnection(connection)
            case .cancelled:
                print("⚠️ Connection cancelled")
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    private func receiveHandshake(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, !data.isEmpty else { return }

            if let handshake = String(data: data, encoding: .utf8) {
                print("📥 Received handshake:\n\(handshake)")

                // Extract WebSocket key
                if let wsKey = self.extractWebSocketKey(from: handshake) {
                    print("🔑 WebSocket Key: \(wsKey)")
                    self.sendHandshakeResponse(to: connection, key: wsKey)
                    self.connectionStates[ObjectIdentifier(connection)] = true
                    print("✅ WebSocket handshake complete")

                    self.sendLatestTelemetryState(to: connection)

                    // Start receiving WebSocket frames
                    self.receiveWebSocketFrame(on: connection)
                } else {
                    print("❌ Failed to extract WebSocket key")
                }
            }
        }
    }

    private func extractWebSocketKey(from handshake: String) -> String? {
        let lines = handshake.components(separatedBy: "\r\n")
        for line in lines {
            if line.starts(with: "Sec-WebSocket-Key:") {
                return line.replacingOccurrences(of: "Sec-WebSocket-Key:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func sendHandshakeResponse(to connection: NWConnection, key: String) {
        let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let acceptKey = key + magicString

        // Compute SHA-1 hash
        let data = Data(acceptKey.utf8)
        let hash = Insecure.SHA1.hash(data: data)
        let acceptValue = Data(hash).base64EncodedString()

        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptValue)\r
        \r

        """

        print("📤 Sending handshake response")
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ error in
            if let error = error {
                print("❌ Failed to send handshake: \(error)")
            } else {
                print("✅ Handshake sent successfully")
            }
        }))
    }

    private func receiveWebSocketFrame(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Receive error: \(error)")
                return
            }

            if let data = data, !data.isEmpty {
                if let message = self.decodeWebSocketFrame(data) {
                    DispatchQueue.main.async {
                        self.lastMessage = message
                        print("📱 Received WebSocket message: \(message)")

                        self.handleIncomingMessage(message)
                    }
                }
            }

            if !isComplete {
                self.receiveWebSocketFrame(on: connection)
            }
        }
    }

    private func decodeWebSocketFrame(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }

        let bytes = [UInt8](data)

        // Parse WebSocket frame
        let masked = (bytes[1] & 0x80) != 0
        var payloadLength = Int(bytes[1] & 0x7F)
        var maskingKeyIndex = 2

        if payloadLength == 126 {
            guard data.count >= 4 else { return nil }
            payloadLength = Int(bytes[2]) << 8 | Int(bytes[3])
            maskingKeyIndex = 4
        } else if payloadLength == 127 {
            guard data.count >= 10 else { return nil }
            maskingKeyIndex = 10
        }

        guard masked else {
            print("⚠️ Frame not masked")
            return nil
        }

        let maskingKey = Array(bytes[maskingKeyIndex..<maskingKeyIndex + 4])
        let payloadStart = maskingKeyIndex + 4

        guard data.count >= payloadStart + payloadLength else { return nil }

        var payload = Array(bytes[payloadStart..<payloadStart + payloadLength])

        // Unmask payload
        for i in 0..<payload.count {
            payload[i] ^= maskingKey[i % 4]
        }

        return String(bytes: payload, encoding: .utf8)
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        connectionStates.removeValue(forKey: ObjectIdentifier(connection))
        if connections.isEmpty {
            bluetoothManager?.sendMessage("0 0 0")
        }
        DispatchQueue.main.async {
            self.connectedClients = self.connections.count
        }
    }

    private func getLocalIPAddress() {
        var address: String = "Not available"

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            localIPAddress = address
            return
        }
        guard let firstAddr = ifaddr else {
            localIPAddress = address
            return
        }

        // Priority order: en0 (WiFi), bridge100 (Hotspot), pdp_ip0 (Cellular), any other valid IP
        var foundAddresses: [String: String] = [:]

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, socklen_t(0), NI_NUMERICHOST)
                let ipAddress = String(cString: hostname)

                // Skip localhost
                if ipAddress != "127.0.0.1" && !ipAddress.isEmpty {
                    foundAddresses[name] = ipAddress
                    print("🔍 Found interface \(name): \(ipAddress)")
                }
            }
        }
        freeifaddrs(ifaddr)

        // Priority: WiFi > Hotspot > Cellular > Any other
        if let ip = foundAddresses["en0"] {
            address = ip
        } else if let ip = foundAddresses["bridge100"] {
            address = ip
        } else if let ip = foundAddresses["pdp_ip0"] {
            address = ip
        } else if let ip = foundAddresses.values.first {
            address = ip
        }

        localIPAddress = address
        print("📍 Local IP: \(address)")
    }

    // MARK: - Broadcasting

    func broadcastBinaryData(_ data: Data) {
        let frame = createBinaryFrame(data: data)

        for connection in connections {
            // Only send to connections that completed handshake
            guard connectionStates[ObjectIdentifier(connection)] == true else { continue }

            connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send binary data: \(error)")
                    self.removeConnection(connection)
                }
            })
        }
    }

    func broadcastPointCloud(
        timestamp: Double,
        pointsPointer: UnsafePointer<Float32>,
        pointCount: Int,
        colorsPointer: UnsafePointer<UInt8>?,
        colorsCount: Int
    ) {
        guard let payload = makeBinaryPointCloudPayload(
            timestamp: timestamp,
            pointsPointer: pointsPointer,
            pointCount: pointCount,
            colorsPointer: colorsPointer,
            colorsCount: colorsCount
        ) else {
            return
        }

        broadcastPointCloudPayload(payload)
    }

    func broadcastPointCloudPayload(_ payload: Data) {
        guard !payload.isEmpty else { return }
        latestPointCloudData = payload
        let frame = createBinaryFrame(data: payload)

        for connection in connections {
            guard connectionStates[ObjectIdentifier(connection)] == true else { continue }

            connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send point cloud: \(error)")
                    self.removeConnection(connection)
                }
            })
        }
    }

    func broadcastTextMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        let frame = createTextFrame(data: data)

        for connection in connections {
            // Only send to connections that completed handshake
            guard connectionStates[ObjectIdentifier(connection)] == true else { continue }

            connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send text message: \(error)")
                }
            })
        }
    }

    func publishTeleopLatencyMetric(_ metric: TeleopLatencyMetric) {
        guard let payload = makeJSONString([
            "type": "teleop_latency",
            "seq": metric.seq,
            "phone_rx_to_ble_ms": metric.phoneRxToBleMs,
            "ble_to_odom_ms": metric.bleToOdomMs,
            "phone_rx_to_odom_ms": metric.phoneRxToOdomMs,
            "odom_seq": metric.odomSeq,
            "sum_dl_ticks": metric.sumDlTicks,
            "sum_dr_ticks": metric.sumDrTicks,
            "left_percent": metric.leftPercent,
            "right_percent": metric.rightPercent,
            "hold_ms": metric.holdMs
        ]) else {
            return
        }
        broadcastTextMessage(payload)
    }

    func publishTeleopLatencyTimeout(seq: Int) {
        guard let payload = makeJSONString([
            "type": "teleop_latency_timeout",
            "seq": seq
        ]) else {
            return
        }
        broadcastTextMessage(payload)
    }

    func publishMapFrame(timestamp: Double, jpegData: Data) {
        guard !jpegData.isEmpty,
              let payload = makeJSONString([
                "type": "map_frame",
                "timestamp": timestamp,
                "jpeg_b64": jpegData.base64EncodedString()
              ]) else {
            return
        }
        latestMapFrameMessage = payload
        broadcastTextMessage(payload)
    }

    func publishMapFrameReset() {
        latestMapFrameMessage = nil
        latestMapLayerPayloads.removeAll()
        guard let payload = makeJSONString([
            "type": "map_frame_reset"
        ]) else {
            return
        }
        broadcastTextMessage(payload)
    }

    func publishMapLayerFrame(
        timestamp: Double,
        layer: String,
        width: Int,
        height: Int,
        channels: Int,
        rgbaPointer: UnsafePointer<UInt8>,
        dataCount: Int
    ) {
        guard let payload = makeBinaryMapLayerPayload(
            timestamp: timestamp,
            layer: layer,
            width: width,
            height: height,
            channels: channels,
            rgbaPointer: rgbaPointer,
            dataCount: dataCount
        ) else {
            return
        }
        latestMapLayerPayloads[layer] = payload
        broadcastBinaryData(payload)
    }

    func publishWasmControlState() {
        DownloadManager.shared.refreshDownloadedFiles()
        let files = availableWasmTargets()
        if !files.contains(where: { ($0["id"] as? String) == selectedWasmTargetId }) {
            selectedWasmTargetId = Self.defaultBundledWasmId
        }

        let selectedName = wasmTargetName(for: selectedWasmTargetId) ?? Self.defaultBundledWasmName
        guard let payload = makeJSONString([
            "type": "wasm_state",
            "is_running": WasmManager.shared.isRunning,
            "selected_target_id": selectedWasmTargetId,
            "selected_target_name": selectedName,
            "running_file_name": WasmManager.shared.currentRunDisplayName ?? "",
            "files": files,
            "hub_files": availableHubFiles(),
            "is_loading_hub": WasmHubService.shared.isLoadingPublic,
            "hub_error": WasmHubService.shared.error ?? ""
        ]) else {
            return
        }

        latestWasmStateMessage = payload
        broadcastTextMessage(payload)
    }

    func publishWasmConsoleLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let payload = makeJSONString([
                "type": "wasm_log",
                "text": trimmed
              ]) else {
            return
        }

        recentWasmLogMessages.append(payload)
        if recentWasmLogMessages.count > Self.maxRecentWasmLogs {
            recentWasmLogMessages.removeFirst(recentWasmLogMessages.count - Self.maxRecentWasmLogs)
        }

        broadcastTextMessage(payload)
    }

    func publishWasmConsoleReset() {
        recentWasmLogMessages.removeAll()
        guard let payload = makeJSONString([
            "type": "wasm_console_reset"
        ]) else {
            return
        }
        broadcastTextMessage(payload)
    }

    func publishMlDetections(
        frame: CameraImageFrame,
        modelResults: [ActiveModelFrameDetections]
    ) {
        let models: [[String: Any]] = modelResults.map { model in
            [
                "model_id": model.modelId,
                "model_name": model.modelName,
                "manifest_name": model.manifestName,
                "status": model.result.status.rawValue,
                "detections": model.result.detections.map { detection in
                    var serializedDetection: [String: Any] = [
                        "class_id": detection.classId,
                        "score": detection.score,
                        "x_min": detection.xMin,
                        "y_min": detection.yMin,
                        "x_max": detection.xMax,
                        "y_max": detection.yMax
                    ]
                    if let labelName = detection.labelName, !labelName.isEmpty {
                        serializedDetection["label_name"] = labelName
                    }
                    return serializedDetection
                }
            ]
        }

        guard let payload = makeJSONString([
            "type": "ml_detections",
            "timestamp": frame.timestamp,
            "image_width": frame.width,
            "image_height": frame.height,
            "models": models
        ]) else {
            return
        }

        latestMlDetectionsMessage = payload
        broadcastTextMessage(payload)
    }

    func publishMlDetectionsReset() {
        latestMlDetectionsMessage = nil
        guard let payload = makeJSONString([
            "type": "ml_detections_reset"
        ]) else {
            return
        }
        broadcastTextMessage(payload)
    }

    // MARK: - WebSocket Frame Creation

    private func createBinaryFrame(data: Data) -> Data {
        var frame = Data()

        // FIN bit set, opcode 0x2 (binary)
        frame.append(0x82)

        // Payload length (server-to-client frames are not masked)
        let length = data.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length < 65536 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        // Append payload
        frame.append(data)

        return frame
    }

    private func sendLatestTelemetryState(to connection: NWConnection) {
        if let latestWasmStateMessage {
            sendTextFrame(latestWasmStateMessage, to: connection, label: "latest wasm state")
        } else {
            publishWasmControlState()
            if let latestWasmStateMessage {
                sendTextFrame(latestWasmStateMessage, to: connection, label: "latest wasm state")
            }
        }

        if let latestMapFrameMessage {
            sendTextFrame(latestMapFrameMessage, to: connection, label: "latest map frame")
        }
        for (_, payload) in latestMapLayerPayloads.sorted(by: {
            mapLayerSortIndex($0.key) < mapLayerSortIndex($1.key)
        }) {
            let frame = createBinaryFrame(data: payload)
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send latest map layer: \(error)")
                }
            })
        }

        for payload in recentWasmLogMessages {
            sendTextFrame(payload, to: connection, label: "recent wasm log")
        }

        if let latestMlDetectionsMessage {
            sendTextFrame(latestMlDetectionsMessage, to: connection, label: "latest ml detections")
        }

        sendLatestPointCloud(to: connection)
    }

    private func sendLatestPointCloud(to connection: NWConnection) {
        guard let latestPointCloudData else { return }
        let frame = createBinaryFrame(data: latestPointCloudData)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Failed to send latest point cloud: \(error)")
            }
        })
    }

    private func sendTextFrame(_ message: String, to connection: NWConnection, label: String) {
        guard let data = message.data(using: .utf8) else { return }
        let frame = createTextFrame(data: data)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Failed to send \(label): \(error)")
            }
        })
    }

    private func createTextFrame(data: Data) -> Data {
        var frame = Data()

        // FIN bit set, opcode 0x1 (text)
        frame.append(0x81)

        // Payload length
        let length = data.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length < 65536 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        // Append payload
        frame.append(data)

        return frame
    }

    private func handleIncomingMessage(_ message: String) {
        if handleWasmControlMessage(message) {
            return
        }

        if let teleopCommand = parseTeleopCommand(message) {
            let phoneReceivedAt = Date().timeIntervalSince1970
            if let btManager = bluetoothManager {
                let result = btManager.sendTeleopMotorCommand(
                    left: teleopCommand.left,
                    right: teleopCommand.right,
                    holdMs: teleopCommand.holdMs,
                    seq: teleopCommand.seq,
                    phoneReceivedAt: phoneReceivedAt
                )
                publishTeleopAck(
                    seq: teleopCommand.seq,
                    forwarded: result.forwarded,
                    sampledForLatency: result.sampledForLatency
                )
                if result.forwarded {
                    print("📤 Forwarded teleop seq \(teleopCommand.seq) to Bluetooth")
                } else {
                    print("⚠️ Failed to forward teleop seq \(teleopCommand.seq)")
                }
            } else {
                publishTeleopAck(seq: teleopCommand.seq, forwarded: false, sampledForLatency: false)
                print("⚠️ Bluetooth manager not available")
            }
            return
        }

        // Forward any legacy/raw messages to Bluetooth unchanged.
        if let btManager = bluetoothManager {
            btManager.sendMessage(message)
            print("📤 Forwarded to Bluetooth: \(message)")
        } else {
            print("⚠️ Bluetooth manager not available")
        }
    }

    private func handleWasmControlMessage(_ message: String) -> Bool {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let type = json["type"] as? String else {
            return false
        }

        switch type {
        case "wasm_select":
            guard let targetId = json["target_id"] as? String else { return true }
            selectWasmTarget(targetId)
            return true
        case "wasm_download":
            guard let remoteId = json["remote_id"] as? String else { return true }
            downloadWasmHubFile(remoteId: remoteId)
            return true
        case "wasm_run":
            runSelectedWasm()
            return true
        case "wasm_stop":
            stopSelectedWasm()
            return true
        case "emergency_stop":
            triggerEmergencyStop()
            return true
        case "wasm_refresh":
            refreshWasmHubFiles()
            return true
        default:
            return false
        }
    }

    private func selectWasmTarget(_ targetId: String) {
        guard !WasmManager.shared.isRunning else {
            publishWasmConsoleLine("[web][wasm] stop the current module before changing selection")
            publishWasmControlState()
            return
        }

        guard wasmTargetName(for: targetId) != nil else {
            publishWasmConsoleLine("[web][wasm] unknown selection \(targetId)")
            publishWasmControlState()
            return
        }

        selectedWasmTargetId = targetId
        publishWasmControlState()
    }

    private func runSelectedWasm() {
        guard !WasmManager.shared.isRunning else {
            publishWasmControlState()
            return
        }

        let targetId = selectedWasmTargetId
        guard let targetName = wasmTargetName(for: targetId) else {
            publishWasmConsoleLine("[web][wasm] no valid WASM target selected")
            publishWasmControlState()
            return
        }

        publishWasmConsoleLine("[web][wasm] starting \(targetName)")
        publishWasmControlState()
        let localFile = localWasmFile(for: targetId)

        DispatchQueue.global(qos: .userInitiated).async {
            WasmManager.shared.startConfiguredHostSensors()

            if targetId == Self.defaultBundledWasmId {
                WasmManager.shared.runWasmFile(named: targetName)
            } else if let file = localFile {
                WasmManager.shared.runWasmFile(at: file.fileURL)
            } else {
                WebSocketManager.shared.publishWasmConsoleLine("[web][wasm] selected file is no longer available")
            }

            WasmManager.shared.stopConfiguredHostSensors()
            WebSocketManager.shared.publishWasmControlState()
        }
    }

    private func stopSelectedWasm() {
        WasmManager.shared.stop()
        WasmManager.shared.stopConfiguredHostSensors()
        publishWasmControlState()
    }

    private func triggerEmergencyStop() {
        publishWasmConsoleLine("[web][estop] emergency stop triggered")
        WasmManager.shared.stop()
        WasmManager.shared.stopConfiguredHostSensors()
        bluetoothManager?.emergencyStop()
        publishWasmControlState()
    }

    private func refreshWasmHubFiles() {
        publishWasmControlState()
        Task {
            await WasmHubService.shared.fetchPublicFiles()
            self.publishWasmControlState()
        }
    }

    private func downloadWasmHubFile(remoteId: String) {
        guard let file = WasmHubService.shared.publicFiles.first(where: { $0.id == remoteId }) else {
            publishWasmConsoleLine("[web][wasmhub] unknown file \(remoteId)")
            publishWasmControlState()
            return
        }

        publishWasmConsoleLine("[web][wasmhub] downloading \(file.name)")
        publishWasmControlState()

        Task {
            do {
                let localFile = try await DownloadManager.shared.download(file: file)
                self.selectedWasmTargetId = "local:\(localFile.id)"
                self.publishWasmConsoleLine("[web][wasmhub] downloaded \(file.name)")
            } catch {
                self.publishWasmConsoleLine("[web][wasmhub] download failed: \(error.localizedDescription)")
            }
            self.publishWasmControlState()
        }
    }

    private func availableWasmTargets() -> [[String: Any]] {
        var targets: [[String: Any]] = [[
            "id": Self.defaultBundledWasmId,
            "name": Self.defaultBundledWasmName,
            "kind": "bundled",
            "detail": "Built into the app"
        ]]

        let downloadedTargets = DownloadManager.shared.downloadedFiles
            .filter(\.exists)
            .map { file in
                [
                    "id": "local:\(file.id)",
                    "name": file.name,
                    "kind": "downloaded",
                    "detail": file.fileName,
                    "uploader_name": file.uploaderName,
                    "file_size": file.formattedFileSize
                ] as [String : Any]
            }

        targets.append(contentsOf: downloadedTargets)
        return targets
    }

    private func availableHubFiles() -> [[String: Any]] {
        WasmHubService.shared.publicFiles.compactMap { file in
            guard let remoteId = file.id else { return nil }
            return [
                "id": remoteId,
                "name": file.name,
                "file_name": file.fileName,
                "description": file.description,
                "uploader_name": file.uploaderName,
                "file_size": file.formattedFileSize,
                "download_count": file.downloadCount,
                "is_downloaded": DownloadManager.shared.isDownloaded(fileId: remoteId)
            ]
        }
    }

    private func wasmTargetName(for targetId: String) -> String? {
        if targetId == Self.defaultBundledWasmId {
            return Self.defaultBundledWasmName
        }
        return localWasmFile(for: targetId)?.name
    }

    private func localWasmFile(for targetId: String) -> LocalWasmFile? {
        guard targetId.hasPrefix("local:") else { return nil }
        let localId = String(targetId.dropFirst("local:".count))
        return DownloadManager.shared.downloadedFiles.first { $0.id == localId && $0.exists }
    }

    private func publishTeleopAck(seq: Int, forwarded: Bool, sampledForLatency: Bool) {
        guard let payload = makeJSONString([
            "type": "teleop_ack",
            "seq": seq,
            "forwarded": forwarded,
            "sampled_for_latency": sampledForLatency
        ]) else {
            return
        }
        broadcastTextMessage(payload)
    }

    private func makeJSONString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func makeBinaryPointCloudPayload(
        timestamp: Double,
        pointsPointer: UnsafePointer<Float32>,
        pointCount: Int,
        colorsPointer: UnsafePointer<UInt8>?,
        colorsCount: Int
    ) -> Data? {
        guard pointCount > 0 else { return nil }

        let packedPointCount = pointCount * 3
        let pointsByteCount = packedPointCount * MemoryLayout<Float32>.size
        let hasColors = colorsPointer != nil && colorsCount >= packedPointCount
        let colorsByteCount = hasColors ? packedPointCount : 0
        let totalByteCount = RoamrBinaryPointCloudProtocol.headerSize + pointsByteCount + colorsByteCount

        var payload = Data(count: totalByteCount)
        payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let rawPointer = baseAddress.assumingMemoryBound(to: UInt8.self)

            RoamrBinaryPointCloudProtocol.magic.withUnsafeBytes { magicBytes in
                if let magicBase = magicBytes.baseAddress {
                    memcpy(rawPointer, magicBase, RoamrBinaryPointCloudProtocol.magic.count)
                }
            }

            rawPointer[4] = RoamrBinaryPointCloudProtocol.messageTypePoints
            rawPointer[RoamrBinaryPointCloudProtocol.flagsOffset] = hasColors
                ? RoamrBinaryPointCloudProtocol.hasColorsFlag
                : 0

            var reserved: UInt16 = 0
            withUnsafeBytes(of: &reserved) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(rawPointer.advanced(by: 6), src, MemoryLayout<UInt16>.size)
                }
            }

            var timestampBits = timestamp.bitPattern.littleEndian
            withUnsafeBytes(of: &timestampBits) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RoamrBinaryPointCloudProtocol.timestampOffset),
                        src,
                        MemoryLayout<UInt64>.size
                    )
                }
            }

            var pointCountLE = UInt32(pointCount).littleEndian
            withUnsafeBytes(of: &pointCountLE) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RoamrBinaryPointCloudProtocol.pointCountOffset),
                        src,
                        MemoryLayout<UInt32>.size
                    )
                }
            }

            memcpy(
                rawPointer.advanced(by: RoamrBinaryPointCloudProtocol.headerSize),
                pointsPointer,
                pointsByteCount
            )

            if hasColors, let colorsPointer {
                memcpy(
                    rawPointer.advanced(by: RoamrBinaryPointCloudProtocol.headerSize + pointsByteCount),
                    colorsPointer,
                    colorsByteCount
                )
            }
        }

        return payload
    }

    private func makeBinaryMapLayerPayload(
        timestamp: Double,
        layer: String,
        width: Int,
        height: Int,
        channels: Int,
        rgbaPointer: UnsafePointer<UInt8>,
        dataCount: Int
    ) -> Data? {
        guard !layer.isEmpty,
              width > 0,
              height > 0,
              channels > 0,
              dataCount > 0,
              let layerId = mapLayerIdValue(for: layer) else {
            return nil
        }

        let expectedCount = width * height * channels
        guard dataCount >= expectedCount else {
            return nil
        }

        let totalByteCount = RoamrBinaryMapLayerProtocol.headerSize + expectedCount
        var payload = Data(count: totalByteCount)
        payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let rawPointer = baseAddress.assumingMemoryBound(to: UInt8.self)

            RoamrBinaryMapLayerProtocol.magic.withUnsafeBytes { magicBytes in
                if let magicBase = magicBytes.baseAddress {
                    memcpy(rawPointer, magicBase, RoamrBinaryMapLayerProtocol.magic.count)
                }
            }

            rawPointer[4] = RoamrBinaryMapLayerProtocol.messageTypeLayer
            rawPointer[5] = 0
            rawPointer[6] = 0
            rawPointer[7] = 0

            var timestampBits = timestamp.bitPattern.littleEndian
            withUnsafeBytes(of: &timestampBits) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RoamrBinaryMapLayerProtocol.timestampOffset),
                        src,
                        MemoryLayout<UInt64>.size
                    )
                }
            }

            var widthLE = UInt32(width).littleEndian
            withUnsafeBytes(of: &widthLE) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RoamrBinaryMapLayerProtocol.widthOffset),
                        src,
                        MemoryLayout<UInt32>.size
                    )
                }
            }

            var heightLE = UInt32(height).littleEndian
            withUnsafeBytes(of: &heightLE) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RoamrBinaryMapLayerProtocol.heightOffset),
                        src,
                        MemoryLayout<UInt32>.size
                    )
                }
            }

            var channelsLE = UInt32(channels).littleEndian
            withUnsafeBytes(of: &channelsLE) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RoamrBinaryMapLayerProtocol.channelsOffset),
                        src,
                        MemoryLayout<UInt32>.size
                    )
                }
            }

            var layerIdLE = UInt32(layerId).littleEndian
            withUnsafeBytes(of: &layerIdLE) { bytes in
                if let src = bytes.baseAddress {
                    memcpy(
                        rawPointer.advanced(by: RoamrBinaryMapLayerProtocol.layerIdOffset),
                        src,
                        MemoryLayout<UInt32>.size
                    )
                }
            }

            memcpy(
                rawPointer.advanced(by: RoamrBinaryMapLayerProtocol.headerSize),
                rgbaPointer,
                expectedCount
            )
        }

        return payload
    }

    private func mapLayerIdValue(for layer: String) -> UInt32? {
        switch layer {
        case "base":
            return 1
        case "odometry":
            return 2
        case "planning":
            return 3
        case "frontiers":
            return 4
        default:
            return nil
        }
    }

    private func mapLayerSortIndex(_ layer: String) -> Int {
        switch layer {
        case "base":
            return 0
        case "odometry":
            return 1
        case "planning":
            return 2
        case "frontiers":
            return 3
        default:
            return Int.max
        }
    }
}

private func parseTeleopCommand(_ text: String) -> IncomingTeleopCommand? {
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    guard tokens.count == 5,
          String(tokens[0]) == "TELEOP",
          let seq = Int(tokens[1]),
          let left = Int(tokens[2]),
          let right = Int(tokens[3]),
          let holdMs = Int(tokens[4]) else {
        return nil
    }
    return IncomingTeleopCommand(seq: seq, left: left, right: right, holdMs: holdMs)
}
