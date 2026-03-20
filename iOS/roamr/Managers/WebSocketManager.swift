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

private enum RoamrWebSocketCompatibility {
    static let protocolVersion = "2026-03-19.1"
    static let webClientName = "roamr-web"
}

private struct WebSocketRollingTimingStat {
    private(set) var totalSeconds: Double = 0
    private(set) var maxSeconds: Double = 0
    private(set) var sampleCount: Int = 0

    mutating func record(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        totalSeconds += seconds
        maxSeconds = max(maxSeconds, seconds)
        sampleCount += 1
    }

    var averageMilliseconds: Double {
        guard sampleCount > 0 else { return 0 }
        return (totalSeconds / Double(sampleCount)) * 1000.0
    }

    var maxMilliseconds: Double {
        maxSeconds * 1000.0
    }
}

private struct PointCloudProfileWindow {
    var windowStartTime: CFAbsoluteTime = 0
    var messages: Int = 0
    var totalPoints: Int = 0
    var totalBytes: Int = 0
    var payloadBuild = WebSocketRollingTimingStat()
    var sendEnqueue = WebSocketRollingTimingStat()

    mutating func reset(startTime: CFAbsoluteTime) {
        self = PointCloudProfileWindow(windowStartTime: startTime)
    }
}

private struct BestEffortMediaFrame {
    let key: String
    let frame: Data
}

private struct MediaSendState {
    var isSending = false
    var pendingFrames: [String: Data] = [:]
}

private struct WasmUploadSession {
    let fileName: String
    let expectedSize: Int
    let expectedChunks: Int
    var receivedChunks: Int = 0
    var data = Data()
}

private struct DecodedWebSocketFrame {
    let fin: Bool
    let opcode: UInt8
    let payload: Data
}

private struct PartialIncomingWebSocketMessage {
    let opcode: UInt8
    var payload: Data
}

private enum IncomingWebSocketFrame {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(Data)
}

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

private enum RoamrBinaryUploadProtocol {
    static let magic: [UInt8] = [0x52, 0x52, 0x55, 0x31]  // "RRU1"
    static let messageTypeBegin: UInt8 = 1
    static let messageTypeChunk: UInt8 = 2
    static let messageTypeComplete: UInt8 = 3
    static let beginHeaderSize = 14
    static let chunkHeaderSize = 8
    static let completeHeaderSize = 5
}

private enum MediaTopicKey {
    static let video = "video"
    static let pointCloud = "pointcloud"

    static func mapLayer(_ layer: String) -> String {
        "map:\(layer)"
    }
}

private struct IncomingTeleopCommand {
    let seq: Int
    let left: Int
    let right: Int
    let holdMs: Int
}

struct MapMetadataSnapshot: Equatable {
    let width: Int
    let height: Int
    let resolutionM: Double
    let originXM: Double
    let originYM: Double
    let originInitialized: Bool
}

struct PlannerGridCell: Codable, Equatable, Hashable, Identifiable {
    let x: Int
    let y: Int

    var id: String {
        "\(x),\(y)"
    }
}

enum PlannerTelemetryMode: String, Codable {
    case none = "none"
    case directGoalDStar = "direct_goal_dstar"
    case frontier = "frontier"
}

struct PlannerTelemetrySnapshot: Codable, Equatable, Identifiable {
    let sequence: UInt64
    let plannerMode: PlannerTelemetryMode
    let sourceMapRevision: UInt64
    let goalRevision: UInt64
    let timestamp: Double
    let success: Bool
    let goalEnabled: Bool
    let startCell: PlannerGridCell?
    let goalCell: PlannerGridCell?
    let pathGrid: [PlannerGridCell]
    let frontierCandidates: [PlannerGridCell]
    let selectedFrontierCluster: [PlannerGridCell]
    let selectedFrontierSeed: PlannerGridCell?
    let changedCells: [PlannerGridCell]
    let expandedCells: [PlannerGridCell]
    let message: String

    var id: UInt64 {
        sequence
    }

    enum CodingKeys: String, CodingKey {
        case sequence
        case plannerMode = "planner_mode"
        case sourceMapRevision = "source_map_revision"
        case goalRevision = "goal_revision"
        case timestamp
        case success
        case goalEnabled = "goal_enabled"
        case startCell = "start_cell"
        case goalCell = "goal_cell"
        case pathGrid = "path_grid"
        case frontierCandidates = "frontier_candidates"
        case selectedFrontierCluster = "selected_frontier_cluster"
        case selectedFrontierSeed = "selected_frontier_seed"
        case changedCells = "changed_cells"
        case expandedCells = "expanded_cells"
        case message
    }
}

private struct PlannerTelemetryMessage: Encodable {
    let type = "planner_telemetry"
    let snapshot: PlannerTelemetrySnapshot
}

private struct PlannerTelemetryResetMessage: Encodable {
    let type = "planner_reset"
}

class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()
    private static let maxRecentWasmLogs = 200
    private static let defaultBundledWasmId = "builtin:slam_main"
    private static let defaultBundledWasmName = "slam_main"
    private let networkQueue = DispatchQueue(label: "roamr.websocket.network", qos: .userInitiated)

    @Published var isServerRunning = false
    @Published var localIPAddress: String = "Not available"
    @Published var serverStatus: String = "Stopped"
    @Published var lastMessage: String = ""
    @Published var connectedClients: Int = 0
    @Published private(set) var latestMapMetadata: MapMetadataSnapshot?
    @Published private(set) var latestPlannerTelemetry: PlannerTelemetrySnapshot?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var connectionStates: [ObjectIdentifier: Bool] = [:] // Track handshake completion
    private var incomingHandshakeBuffers: [ObjectIdentifier: Data] = [:]
    private var incomingFrameBuffers: [ObjectIdentifier: Data] = [:]
    private var partialIncomingMessages: [ObjectIdentifier: PartialIncomingWebSocketMessage] = [:]
    private var mediaSendStates: [ObjectIdentifier: MediaSendState] = [:]
    private var keepaliveTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private var latestPointCloudData: Data?
    private var latestMapFrameMessage: String?
    private var latestMapMetadataMessage: String?
    private var latestMapLayerPayloads: [String: Data] = [:]
    private var latestMlDetectionsMessage: String?
    private var latestWasmStateMessage: String?
    private var latestPoseMessage: String?
    private var latestPlannerTelemetryMessage: String?
    private var latestMapMetadataSnapshot: MapMetadataSnapshot?
    private var latestPlannerTelemetrySnapshot: PlannerTelemetrySnapshot?
    private var recentWasmLogMessages: [String] = []
    private var selectedWasmTargetId: String
    private var wasmUploadSessions: [ObjectIdentifier: WasmUploadSession] = [:]
    private let port: NWEndpoint.Port = 8080
    private let keepalivePingInterval: TimeInterval = 15.0
    private let enablePointCloudProfiling = true
    private let pointCloudProfilingSummaryInterval: TimeInterval = 3.0
    private let pointCloudProfileLock = NSLock()
    private var pointCloudProfileWindow = PointCloudProfileWindow()

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

            listener?.start(queue: networkQueue)
        } catch {
            serverStatus = "Error: \(error.localizedDescription)"
        }
    }

    func stopServer() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        connectionStates.removeAll()
        incomingHandshakeBuffers.removeAll()
        incomingFrameBuffers.removeAll()
        partialIncomingMessages.removeAll()
        mediaSendStates.removeAll()
        keepaliveTimers.values.forEach { timer in
            timer.setEventHandler {}
            timer.cancel()
        }
        keepaliveTimers.removeAll()
        wasmUploadSessions.removeAll()
        isServerRunning = false
        serverStatus = "Stopped"
        connectedClients = 0
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)
        connectedClients = connections.count
        let connectionId = ObjectIdentifier(connection)
        connectionStates[connectionId] = false // Handshake not complete
        incomingHandshakeBuffers[connectionId] = Data()
        incomingFrameBuffers[connectionId] = Data()
        mediaSendStates[connectionId] = MediaSendState()

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

        connection.start(queue: networkQueue)
    }

    private func receiveHandshake(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            let connectionId = ObjectIdentifier(connection)

            if let error {
                print("❌ Handshake receive error: \(error)")
                self.removeConnection(connection)
                return
            }

            if let data, !data.isEmpty {
                var buffer = self.incomingHandshakeBuffers[connectionId] ?? Data()
                buffer.append(data)

                guard let terminatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    self.incomingHandshakeBuffers[connectionId] = buffer
                    if !isComplete {
                        self.receiveHandshake(on: connection)
                    } else {
                        print("❌ Connection closed before WebSocket handshake completed")
                        self.removeConnection(connection)
                    }
                    return
                }

                let headerEnd = terminatorRange.upperBound
                let handshakeData = buffer.prefix(upTo: headerEnd)
                let remainingData = Data(buffer.suffix(from: headerEnd))

                guard let handshake = String(data: handshakeData, encoding: .utf8) else {
                    print("❌ Invalid UTF-8 in WebSocket handshake")
                    self.removeConnection(connection)
                    return
                }

                print("📥 Received handshake:\n\(handshake)")

                guard let wsKey = self.extractWebSocketKey(from: handshake) else {
                    print("❌ Failed to extract WebSocket key")
                    self.removeConnection(connection)
                    return
                }

                print("🔑 WebSocket Key: \(wsKey)")
                self.incomingHandshakeBuffers.removeValue(forKey: connectionId)
                self.sendHandshakeResponse(to: connection, key: wsKey)
                self.connectionStates[connectionId] = true
                self.startKeepalivePingTimer(for: connection)
                print("✅ WebSocket handshake complete")

                if !remainingData.isEmpty {
                    var frameBuffer = self.incomingFrameBuffers[connectionId] ?? Data()
                    frameBuffer.append(remainingData)
                    self.incomingFrameBuffers[connectionId] = frameBuffer
                }

                self.sendLatestTelemetryState(to: connection)
                self.receiveWebSocketFrame(on: connection)
                return
            }

            if isComplete {
                print("❌ Connection closed before WebSocket handshake completed")
                self.removeConnection(connection)
                return
            }

            self.receiveHandshake(on: connection)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Receive error: \(error)")
                self.removeConnection(connection)
                return
            }

            let connectionId = ObjectIdentifier(connection)
            var buffer = self.incomingFrameBuffers[connectionId] ?? Data()

            if let data = data, !data.isEmpty {
                buffer.append(data)
            }

            while let frame = self.decodeNextWebSocketFrame(from: &buffer) {
                guard let assembledFrame = self.assembleIncomingWebSocketFrame(
                    frame,
                    connectionId: connectionId
                ) else {
                    continue
                }

                switch assembledFrame {
                case .text(let message):
                    DispatchQueue.main.async {
                        self.lastMessage = message
                        print("📱 Received WebSocket message: \(message)")
                        self.handleIncomingMessage(message)
                    }
                case .binary(let payload):
                    self.handleIncomingBinaryMessage(payload, from: connection)
                case .ping(let payload):
                    self.sendControlFrame(opcode: 0xA, payload: payload, to: connection)
                case .pong:
                    break
                case .close(let payload):
                    self.sendControlFrame(opcode: 0x8, payload: payload, to: connection)
                    connection.cancel()
                    self.removeConnection(connection)
                    return
                }
            }
            self.incomingFrameBuffers[connectionId] = buffer

            if !isComplete {
                self.receiveWebSocketFrame(on: connection)
            } else {
                self.removeConnection(connection)
            }
        }
    }

    private func decodeNextWebSocketFrame(from buffer: inout Data) -> DecodedWebSocketFrame? {
        guard buffer.count >= 2 else { return nil }

        let bytes = [UInt8](buffer)
        let fin = (bytes[0] & 0x80) != 0
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var payloadLength = Int(bytes[1] & 0x7F)
        var headerLength = 2

        if payloadLength == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLength = Int(bytes[2]) << 8 | Int(bytes[3])
            headerLength = 4
        } else if payloadLength == 127 {
            guard buffer.count >= 10 else { return nil }
            var extendedLength: UInt64 = 0
            for index in 0..<8 {
                extendedLength = (extendedLength << 8) | UInt64(bytes[2 + index])
            }
            guard extendedLength <= UInt64(Int.max) else {
                print("⚠️ WebSocket payload too large")
                buffer.removeAll()
                return nil
            }
            payloadLength = Int(extendedLength)
            headerLength = 10
        }

        guard masked else {
            print("⚠️ Frame not masked")
            buffer.removeAll()
            return nil
        }

        let frameLength = headerLength + 4 + payloadLength
        guard buffer.count >= frameLength else { return nil }

        let maskingKey = Array(bytes[headerLength..<(headerLength + 4)])
        let payloadStart = headerLength + 4
        var payload = Data(buffer[payloadStart..<(payloadStart + payloadLength)])
        payload.withUnsafeMutableBytes { payloadRaw in
            guard let payloadBase = payloadRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            for index in 0..<payloadLength {
                payloadBase[index] ^= maskingKey[index % 4]
            }
        }
        buffer.removeSubrange(0..<frameLength)

        return DecodedWebSocketFrame(fin: fin, opcode: opcode, payload: payload)
    }

    private func assembleIncomingWebSocketFrame(
        _ frame: DecodedWebSocketFrame,
        connectionId: ObjectIdentifier
    ) -> IncomingWebSocketFrame? {
        switch frame.opcode {
        case 0x0:
            guard var partial = partialIncomingMessages[connectionId] else {
                print("⚠️ Received continuation frame without an active fragmented message")
                return nil
            }
            partial.payload.append(frame.payload)
            if frame.fin {
                partialIncomingMessages.removeValue(forKey: connectionId)
                return makeIncomingWebSocketFrame(opcode: partial.opcode, payload: partial.payload)
            }
            partialIncomingMessages[connectionId] = partial
            return nil
        case 0x1, 0x2:
            if frame.fin {
                return makeIncomingWebSocketFrame(opcode: frame.opcode, payload: frame.payload)
            }
            partialIncomingMessages[connectionId] = PartialIncomingWebSocketMessage(
                opcode: frame.opcode,
                payload: frame.payload
            )
            return nil
        case 0x8, 0x9, 0xA:
            return makeIncomingWebSocketFrame(opcode: frame.opcode, payload: frame.payload)
        default:
            print("⚠️ Unsupported WebSocket opcode: \(frame.opcode)")
            return nil
        }
    }

    private func makeIncomingWebSocketFrame(opcode: UInt8, payload: Data) -> IncomingWebSocketFrame? {
        switch opcode {
        case 0x1:
            guard let message = String(data: payload, encoding: .utf8) else {
                return nil
            }
            return .text(message)
        case 0x2:
            return .binary(payload)
        case 0x8:
            return .close(payload)
        case 0x9:
            return .ping(payload)
        case 0xA:
            return .pong(payload)
        default:
            return nil
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)
        connections.removeAll { $0 === connection }
        connectionStates.removeValue(forKey: connectionId)
        incomingHandshakeBuffers.removeValue(forKey: connectionId)
        incomingFrameBuffers.removeValue(forKey: connectionId)
        partialIncomingMessages.removeValue(forKey: connectionId)
        mediaSendStates.removeValue(forKey: connectionId)
        stopKeepalivePingTimer(for: connectionId)
        wasmUploadSessions.removeValue(forKey: connectionId)
        if connections.isEmpty {
            bluetoothManager?.sendMessage("0 0 0")
        }
        DispatchQueue.main.async {
            self.connectedClients = self.connections.count
        }
    }

    private func handleIncomingBinaryMessage(_ payload: Data, from connection: NWConnection) {
        guard payload.count >= 5 else { return }
        let bytes = [UInt8](payload)
        guard Array(bytes.prefix(4)) == RoamrBinaryUploadProtocol.magic else {
            return
        }
        let connectionId = ObjectIdentifier(connection)
        switch bytes[4] {
        case RoamrBinaryUploadProtocol.messageTypeBegin:
            handleBinaryUploadBegin(payload, connectionId: connectionId)
        case RoamrBinaryUploadProtocol.messageTypeChunk:
            handleBinaryUploadChunk(payload, connectionId: connectionId)
        case RoamrBinaryUploadProtocol.messageTypeComplete:
            handleBinaryUploadComplete(connectionId: connectionId)
        default:
            break
        }
    }

    private func sendControlFrame(opcode: UInt8, payload: Data = Data(), to connection: NWConnection) {
        let frame = createControlFrame(opcode: opcode, data: payload)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                print("❌ Failed to send control frame: \(error)")
            }
        })
    }

    private func startKeepalivePingTimer(for connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)
        stopKeepalivePingTimer(for: connectionId)

        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(
            deadline: .now() + keepalivePingInterval,
            repeating: keepalivePingInterval
        )
        timer.setEventHandler { [weak self, weak connection] in
            guard let self else { return }
            guard let connection else {
                self.stopKeepalivePingTimer(for: connectionId)
                return
            }
            guard self.connectionStates[connectionId] == true else {
                self.stopKeepalivePingTimer(for: connectionId)
                return
            }
            self.sendControlFrame(opcode: 0x9, to: connection)
        }
        keepaliveTimers[connectionId] = timer
        timer.resume()
    }

    private func stopKeepalivePingTimer(for connectionId: ObjectIdentifier) {
        guard let timer = keepaliveTimers.removeValue(forKey: connectionId) else {
            return
        }
        timer.setEventHandler {}
        timer.cancel()
    }
    private func shouldRemoveConnection(for error: NWError) -> Bool {
        switch error {
        case .posix(let posixError):
            switch posixError {
            case .ENOTCONN, .ECONNRESET, .EPIPE, .ETIMEDOUT, .ECONNABORTED, .ECONNREFUSED:
                return true
            default:
                return false
            }
        case .tls, .dns:
            return true
        @unknown default:
            return true
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
        broadcastBestEffortBinaryData(data, topicKey: MediaTopicKey.video)
    }

    func broadcastPointCloud(
        timestamp: Double,
        pointsPointer: UnsafePointer<Float32>,
        pointCount: Int,
        colorsPointer: UnsafePointer<UInt8>?,
        colorsCount: Int
    ) {
        let buildStartedAt = CFAbsoluteTimeGetCurrent()
        guard let payload = makeBinaryPointCloudPayload(
            timestamp: timestamp,
            pointsPointer: pointsPointer,
            pointCount: pointCount,
            colorsPointer: colorsPointer,
            colorsCount: colorsCount
        ) else {
            return
        }
        let buildDuration = CFAbsoluteTimeGetCurrent() - buildStartedAt

        let sendStartedAt = CFAbsoluteTimeGetCurrent()
        broadcastPointCloudPayload(payload)
        let sendDuration = CFAbsoluteTimeGetCurrent() - sendStartedAt
        recordPointCloudProfile(
            pointCount: pointCount,
            payloadBytes: payload.count,
            payloadBuildSeconds: buildDuration,
            sendEnqueueSeconds: sendDuration
        )
    }

    func broadcastPointCloudPayload(_ payload: Data) {
        guard !payload.isEmpty else { return }
        latestPointCloudData = payload
        broadcastBestEffortBinaryData(payload, topicKey: MediaTopicKey.pointCloud)
    }

    private func broadcastBestEffortBinaryData(_ data: Data, topicKey: String) {
        let frame = createBinaryFrame(data: data)

        for connection in connections {
            let connectionId = ObjectIdentifier(connection)
            guard connectionStates[connectionId] == true else { continue }
            enqueueBestEffortMediaFrame(frame, topicKey: topicKey, to: connection, connectionId: connectionId)
        }
    }

    private func enqueueBestEffortMediaFrame(
        _ frame: Data,
        topicKey: String,
        to connection: NWConnection,
        connectionId: ObjectIdentifier
    ) {
        networkQueue.async {
            guard self.connectionStates[connectionId] == true else { return }
            var state = self.mediaSendStates[connectionId] ?? MediaSendState()
            state.pendingFrames[topicKey] = frame
            let shouldStartSending = !state.isSending
            if shouldStartSending {
                state.isSending = true
            }
            self.mediaSendStates[connectionId] = state

            if shouldStartSending {
                self.sendNextBestEffortMediaFrame(to: connection, connectionId: connectionId)
            }
        }
    }

    private func sendNextBestEffortMediaFrame(to connection: NWConnection, connectionId: ObjectIdentifier) {
        guard connectionStates[connectionId] == true else {
            mediaSendStates.removeValue(forKey: connectionId)
            return
        }

        var state = mediaSendStates[connectionId] ?? MediaSendState()
        guard let nextFrame = dequeueNextBestEffortMediaFrame(from: &state) else {
            state.isSending = false
            mediaSendStates[connectionId] = state
            return
        }
        mediaSendStates[connectionId] = state

        connection.send(content: nextFrame.frame, completion: .contentProcessed { error in
            self.networkQueue.async {
                if let error = error {
                    print("❌ Failed to send media frame [\(nextFrame.key)]: \(error)")
                    if self.shouldRemoveConnection(for: error) {
                        self.removeConnection(connection)
                        return
                    }
                }
                self.sendNextBestEffortMediaFrame(to: connection, connectionId: connectionId)
            }
        })
    }

    private func dequeueNextBestEffortMediaFrame(from state: inout MediaSendState) -> BestEffortMediaFrame? {
        let nextKey = state.pendingFrames.keys.min { lhs, rhs in
            mediaPriority(for: lhs) < mediaPriority(for: rhs)
        }

        guard let nextKey, let frame = state.pendingFrames.removeValue(forKey: nextKey) else {
            return nil
        }

        return BestEffortMediaFrame(key: nextKey, frame: frame)
    }

    private func mediaPriority(for key: String) -> Int {
        if key == MediaTopicKey.video {
            return 0
        }
        if key == MediaTopicKey.pointCloud {
            return 1
        }
        if key.hasPrefix("map:") {
            return 2
        }
        return 3
    }

    private func recordPointCloudProfile(
        pointCount: Int,
        payloadBytes: Int,
        payloadBuildSeconds: Double,
        sendEnqueueSeconds: Double
    ) {
        guard enablePointCloudProfiling else { return }
        let now = CFAbsoluteTimeGetCurrent()
        pointCloudProfileLock.lock()
        if pointCloudProfileWindow.windowStartTime == 0 {
            pointCloudProfileWindow.windowStartTime = now
        }
        pointCloudProfileWindow.messages += 1
        pointCloudProfileWindow.totalPoints += pointCount
        pointCloudProfileWindow.totalBytes += payloadBytes
        pointCloudProfileWindow.payloadBuild.record(payloadBuildSeconds)
        pointCloudProfileWindow.sendEnqueue.record(sendEnqueueSeconds)
        let summary = makePointCloudProfileSummaryIfNeededLocked(now: now)
        pointCloudProfileLock.unlock()
        if let summary {
            print(summary)
        }
    }

    private func makePointCloudProfileSummaryIfNeededLocked(now: CFAbsoluteTime) -> String? {
        guard pointCloudProfileWindow.windowStartTime > 0 else { return nil }
        let elapsed = now - pointCloudProfileWindow.windowStartTime
        guard elapsed >= pointCloudProfilingSummaryInterval else { return nil }
        let messages = pointCloudProfileWindow.messages
        let avgPoints = messages > 0 ? Double(pointCloudProfileWindow.totalPoints) / Double(messages) : 0
        let avgBytes = messages > 0 ? Double(pointCloudProfileWindow.totalBytes) / Double(messages) : 0
        let summary = String(
            format: "[ws][pointcloud] window=%.1fs msgs=%d avg_pts=%.0f avg_bytes=%.0f build=%.3f/%.3fms send=%.3f/%.3fms clients=%d",
            elapsed,
            messages,
            avgPoints,
            avgBytes,
            pointCloudProfileWindow.payloadBuild.averageMilliseconds,
            pointCloudProfileWindow.payloadBuild.maxMilliseconds,
            pointCloudProfileWindow.sendEnqueue.averageMilliseconds,
            pointCloudProfileWindow.sendEnqueue.maxMilliseconds,
            connectedClients
        )
        pointCloudProfileWindow.reset(startTime: now)
        return summary
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
                    if self.shouldRemoveConnection(for: error) {
                        self.removeConnection(connection)
                    }
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

    func publishMapMetadata(
        width: Int,
        height: Int,
        resolutionM: Double,
        originXM: Double,
        originYM: Double,
        originInitialized: Bool
    ) {
        guard width > 0,
              height > 0,
              resolutionM > 0,
              let payload = makeJSONString([
                "type": "map_meta",
                "width": width,
                "height": height,
                "resolution_m": resolutionM,
                "origin_x_m": originXM,
                "origin_y_m": originYM,
                "origin_initialized": originInitialized
              ]) else {
            return
        }
        let snapshot = MapMetadataSnapshot(
            width: width,
            height: height,
            resolutionM: resolutionM,
            originXM: originXM,
            originYM: originYM,
            originInitialized: originInitialized
        )
        latestMapMetadataSnapshot = snapshot
        latestMapMetadataMessage = payload
        DispatchQueue.main.async {
            self.latestMapMetadata = snapshot
        }
        broadcastTextMessage(payload)
    }

    func publishMapFrameReset() {
        latestMapFrameMessage = nil
        latestMapMetadataMessage = nil
        latestMapMetadataSnapshot = nil
        latestMapLayerPayloads.removeAll()
        DispatchQueue.main.async {
            self.latestMapMetadata = nil
        }
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
        broadcastBestEffortBinaryData(payload, topicKey: MediaTopicKey.mapLayer(layer))
    }

    func publishPose(
        timestamp: Double,
        translation: [Double],
        quaternion: [Double],
        source: String
    ) {
        guard timestamp > 0,
              translation.count == 3,
              quaternion.count == 4,
              let payload = makeJSONString([
                "type": "pose",
                "timestamp": timestamp,
                "translation": translation,
                "quaternion": quaternion,
                "pose_source": source
              ]) else {
            return
        }
        latestPoseMessage = payload
        broadcastTextMessage(payload)
    }

    func publishPlannerTelemetry(_ snapshot: PlannerTelemetrySnapshot) {
        latestPlannerTelemetrySnapshot = snapshot
        guard let latestPayload = makeJSONText(PlannerTelemetryMessage(snapshot: snapshot)) else {
            return
        }

        latestPlannerTelemetryMessage = latestPayload
        DispatchQueue.main.async {
            self.latestPlannerTelemetry = snapshot
        }

        broadcastTextMessage(latestPayload)
    }

    func publishPlannerTelemetryReset() {
        latestPlannerTelemetrySnapshot = nil
        latestPlannerTelemetryMessage = nil
        DispatchQueue.main.async {
            self.latestPlannerTelemetry = nil
        }
        guard let payload = makeJSONText(PlannerTelemetryResetMessage()) else {
            return
        }
        broadcastTextMessage(payload)
    }

    func publishWasmControlState() {
        DownloadManager.shared.refreshDownloadedFiles()
        MLBundleManager.shared.refreshBundles()
        let files = availableWasmTargets()
        if !files.contains(where: { ($0["id"] as? String) == selectedWasmTargetId }) {
            selectedWasmTargetId = Self.defaultBundledWasmId
        }

        let selectedName = wasmTargetName(for: selectedWasmTargetId) ?? Self.defaultBundledWasmName
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        guard let payload = makeJSONString([
            "type": "wasm_state",
            "is_running": WasmManager.shared.isRunning,
            "selected_target_id": selectedWasmTargetId,
            "selected_target_name": selectedName,
            "running_file_name": WasmManager.shared.currentRunDisplayName ?? "",
            "compatibility": [
                "protocol_version": RoamrWebSocketCompatibility.protocolVersion,
                "server_name": "roamr-ios",
                "web_client_name": RoamrWebSocketCompatibility.webClientName,
                "app_version": appVersion,
                "build_version": buildVersion
            ],
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

    private func createControlFrame(opcode: UInt8, data: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)

        let length = min(data.count, 125)
        frame.append(UInt8(length))
        if length > 0 {
            frame.append(data.prefix(length))
        }

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

        if let latestMapMetadataMessage {
            sendTextFrame(latestMapMetadataMessage, to: connection, label: "latest map metadata")
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

        if let latestPoseMessage {
            sendTextFrame(latestPoseMessage, to: connection, label: "latest pose")
        }

        if let latestPlannerTelemetryMessage {
            sendTextFrame(latestPlannerTelemetryMessage, to: connection, label: "latest planner telemetry")
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

    private func handleBinaryUploadBegin(_ payload: Data, connectionId: ObjectIdentifier) {
        guard payload.count >= RoamrBinaryUploadProtocol.beginHeaderSize else {
            publishWasmConsoleLine("[web][upload] invalid upload begin frame")
            return
        }
        let totalSize = readUInt32LE(payload, offset: 6)
        let totalChunks = Int(readUInt16LE(payload, offset: 10))
        let fileNameLength = Int(readUInt16LE(payload, offset: 12))
        let fileNameStart = RoamrBinaryUploadProtocol.beginHeaderSize
        let fileNameEnd = fileNameStart + fileNameLength
        guard totalSize > 0,
              totalChunks > 0,
              payload.count >= fileNameEnd,
              let fileName = String(data: payload[fileNameStart..<fileNameEnd], encoding: .utf8),
              !fileName.isEmpty else {
            publishWasmConsoleLine("[web][upload] invalid upload metadata")
            return
        }

        wasmUploadSessions[connectionId] = WasmUploadSession(
            fileName: fileName,
            expectedSize: Int(totalSize),
            expectedChunks: totalChunks
        )
        publishWasmConsoleLine("[web][upload] receiving \(fileName) (\(totalSize) bytes)")
    }

    private func handleBinaryUploadChunk(_ payload: Data, connectionId: ObjectIdentifier) {
        guard var session = wasmUploadSessions[connectionId] else {
            publishWasmConsoleLine("[web][upload] chunk received without active upload")
            return
        }
        guard payload.count >= RoamrBinaryUploadProtocol.chunkHeaderSize else {
            publishWasmConsoleLine("[web][upload] invalid upload chunk frame")
            wasmUploadSessions.removeValue(forKey: connectionId)
            return
        }

        let chunkIndex = Int(readUInt16LE(payload, offset: 6))
        let expectedChunkIndex = session.receivedChunks
        guard chunkIndex == expectedChunkIndex else {
            publishWasmConsoleLine("[web][upload] chunk order mismatch for \(session.fileName)")
            wasmUploadSessions.removeValue(forKey: connectionId)
            return
        }

        let chunkData = payload.suffix(from: RoamrBinaryUploadProtocol.chunkHeaderSize)
        session.data.append(chunkData)
        session.receivedChunks += 1
        if session.data.count > session.expectedSize {
            publishWasmConsoleLine("[web][upload] upload exceeded declared size")
            wasmUploadSessions.removeValue(forKey: connectionId)
            return
        }
        wasmUploadSessions[connectionId] = session
    }

    private func handleBinaryUploadComplete(connectionId: ObjectIdentifier) {
        guard let session = wasmUploadSessions.removeValue(forKey: connectionId) else {
            publishWasmConsoleLine("[web][upload] upload completion without active upload")
            return
        }
        guard session.receivedChunks == session.expectedChunks else {
            publishWasmConsoleLine("[web][upload] chunk count mismatch for \(session.fileName)")
            return
        }
        guard session.data.count == session.expectedSize else {
            publishWasmConsoleLine(
                "[web][upload] size mismatch for \(session.fileName) expected \(session.expectedSize) got \(session.data.count)"
            )
            return
        }

        do {
            let localFile = try DownloadManager.shared.importUploadedWasm(
                data: session.data,
                fileName: session.fileName
            )
            DownloadManager.shared.refreshDownloadedFiles()
            selectedWasmTargetId = "local:\(localFile.id)"
            publishWasmConsoleLine("[web][upload] saved \(session.fileName)")
            publishWasmControlState()
        } catch {
            publishWasmConsoleLine("[web][upload] failed: \(error.localizedDescription)")
        }
    }

    private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            | (UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8)
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return UInt32(data[data.index(data.startIndex, offsetBy: offset)])
            | (UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8)
            | (UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)]) << 16)
            | (UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)]) << 24)
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
        let localBundle = localMLBundle(for: targetId)

        DispatchQueue.global(qos: .userInitiated).async {
            WasmManager.shared.startConfiguredHostSensors()

            if targetId == Self.defaultBundledWasmId {
                WasmManager.shared.runWasmFile(named: targetName)
            } else if let file = localFile {
                WasmManager.shared.runWasmFile(at: file.fileURL)
            } else if let bundle = localBundle {
                WasmManager.shared.runWasmFile(at: bundle.entryWasmURL)
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
        var targets: [[String: Any]] = []
        targets.append([
            "id": Self.defaultBundledWasmId,
            "name": Self.defaultBundledWasmName,
            "kind": "bundled",
            "detail": "Built into the app"
        ])

        for file in DownloadManager.shared.downloadedFiles where file.exists {
            let isUploaded = file.remoteId.hasPrefix("upload:")
            targets.append([
                "id": "local:\(file.id)",
                "name": file.name,
                "kind": isUploaded ? "uploaded" : "downloaded",
                "detail": file.fileName,
                "uploader_name": file.uploaderName,
                "file_size": file.formattedFileSize
            ])
        }

        for bundle in MLBundleManager.shared.importedBundles where bundle.exists {
            targets.append([
                "id": "bundle:\(bundle.id)",
                "name": bundle.name,
                "kind": "ml bundle",
                "detail": bundle.entryWasmFileName,
                "file_size": bundle.formattedFileSize
            ])
        }

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
        return localWasmFile(for: targetId)?.name ?? localMLBundle(for: targetId)?.name
    }

    private func localWasmFile(for targetId: String) -> LocalWasmFile? {
        guard targetId.hasPrefix("local:") else { return nil }
        let localId = String(targetId.dropFirst("local:".count))
        return DownloadManager.shared.downloadedFiles.first { $0.id == localId && $0.exists }
    }

    private func localMLBundle(for targetId: String) -> LocalWasmBundle? {
        guard targetId.hasPrefix("bundle:") else { return nil }
        let bundleId = String(targetId.dropFirst("bundle:".count))
        return MLBundleManager.shared.importedBundles.first { $0.id == bundleId && $0.exists }
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

    private func makeJSONText<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
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
        case "semantic":
            return 5
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
        case "semantic":
            return 4
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
