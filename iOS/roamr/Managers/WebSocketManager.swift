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

class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()

    @Published var isServerRunning = false
    @Published var localIPAddress: String = "Not available"
    @Published var serverStatus: String = "Stopped"
    @Published var lastMessage: String = ""
    @Published var connectedClients: Int = 0

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var connectionStates: [ObjectIdentifier: Bool] = [:] // Track handshake completion
    private let port: NWEndpoint.Port = 8080

    // Bluetooth manager for forwarding messages
    var bluetoothManager: BluetoothManager?

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

                        // Forward to Bluetooth
                        if let btManager = self.bluetoothManager {
                            btManager.sendMessage(message)
                            print("📤 Forwarded to Bluetooth: \(message)")
                        } else {
                            print("⚠️ Bluetooth manager not available")
                        }
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
}
