//
//  BluetoothManager.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-22.
//

import Foundation
import CoreBluetooth
import Combine

private let kEnableVerboseBleLogs = false

struct WheelOdometrySample {
    var timestamp: Double
    var seq: Int32
    var dlTicks: Int32
    var drTicks: Int32
    var samplePeriodMs: Int32
}

struct TeleopForwardResult {
    let forwarded: Bool
    let sampledForLatency: Bool
}

struct TeleopLatencyMetric {
    let seq: Int
    let phoneRxToBleMs: Int
    let bleToOdomMs: Int
    let phoneRxToOdomMs: Int
    let odomSeq: Int
    let sumDlTicks: Int
    let sumDrTicks: Int
    let leftPercent: Int
    let rightPercent: Int
    let holdMs: Int
}

private struct PendingTeleopTrace {
    let seq: Int
    let phoneReceivedAt: TimeInterval
    let bleDispatchedAt: TimeInterval
    let leftPercent: Int
    let rightPercent: Int
    let holdMs: Int
}

class BluetoothManager: NSObject, ObservableObject {
    static let shared = BluetoothManager()

    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectionStatus = "Not Connected"
    @Published var lastMessage = ""
    @Published var lastMotorCommandText = "TX motor: -"
    @Published var lastOdomFrameText = "RX odom: -"
    @Published var lastMotorOdomText = "TX->RX: -"
    @Published var lastTeleopLatencyText = "Teleop latency: -"

    private var centralManager: CBCentralManager!
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var shouldStartScanningWhenReady = false
    private var odomNotifyRequested = false

    private var lastOdomSeq: UInt16?
    private var latestOdomSamplePeriodMs: UInt16 = 20
    private var lastMotorCommandTimestamp: TimeInterval = 0
    private var lastMotorLeftPercent = 0
    private var lastMotorRightPercent = 0
    private var lastMotorHoldMs = 0
    private var pendingTeleopTrace: PendingTeleopTrace?
    private var teleopStopWatchdogToken = 0
    private let odomQueueLock = NSLock()
    private var pendingOdomSamples: [WheelOdometrySample] = []
    private let maxPendingOdomSamples = 12_000
    private let preferredDeviceNameSubstring = "ESP32_C6"
    private let teleopMetricTimeoutMs = 2_000

    // UUIDs matching ESP32 firmware
    private let serviceUUID = CBUUID(string: "00FF")
    private let controlCharacteristicUUID = CBUUID(string: "FF01")
    private let dataCharacteristicUUID = CBUUID(string: "FF02")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            shouldStartScanningWhenReady = true
            connectionStatus = "Waiting for Bluetooth..."
            return
        }
        shouldStartScanningWhenReady = false
        discoveredDevices.removeAll()
        isScanning = true
        connectionStatus = "Scanning..."
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        isScanning = false
        centralManager.stopScan()
        if !isConnected {
            connectionStatus = "Not Connected"
        }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        connectionStatus = "Connecting..."
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let device = connectedDevice {
            centralManager.cancelPeripheralConnection(device)
        }
        startScanning()
    }

    func sendMessage(_ message: String) {
        _ = sendMessageInternal(message, teleopSequence: nil, phoneReceivedAt: nil)
    }

    func sendTeleopMotorCommand(
        left: Int,
        right: Int,
        holdMs: Int,
        seq: Int,
        phoneReceivedAt: TimeInterval
    ) -> TeleopForwardResult {
        prunePendingTeleopTrace(now: Date().timeIntervalSince1970)

        let clampedLeft = max(-100, min(100, left))
        let clampedRight = max(-100, min(100, right))
        let clampedHoldMs = max(0, holdMs)
        let shouldSample = (clampedLeft != 0 || clampedRight != 0) && pendingTeleopTrace == nil
        let forwarded = sendMessageInternal(
            "\(clampedLeft) \(clampedRight) \(clampedHoldMs)",
            teleopSequence: shouldSample ? seq : nil,
            phoneReceivedAt: shouldSample ? phoneReceivedAt : nil
        )
        updateTeleopStopWatchdog(
            left: clampedLeft,
            right: clampedRight,
            holdMs: clampedHoldMs,
            commandWasForwarded: forwarded
        )
        return TeleopForwardResult(forwarded: forwarded, sampledForLatency: forwarded && shouldSample)
    }

    private func updateTeleopStopWatchdog(left: Int, right: Int, holdMs: Int, commandWasForwarded: Bool) {
        teleopStopWatchdogToken += 1
        let token = teleopStopWatchdogToken

        guard commandWasForwarded else { return }

        if left == 0 && right == 0 {
            sendTeleopStopBurst(token: token)
            return
        }

        guard holdMs > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(holdMs)) { [weak self] in
            guard let self, token == self.teleopStopWatchdogToken else { return }
            _ = self.sendMessageInternal("0 0 0", teleopSequence: nil, phoneReceivedAt: nil)
            self.sendTeleopStopBurst(token: token)
        }
    }

    private func sendTeleopStopBurst(token: Int) {
        let burstDelaysMs = [0, 50, 125]
        for delayMs in burstDelaysMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self, token == self.teleopStopWatchdogToken else { return }
                _ = self.sendMessageInternal("0 0 0", teleopSequence: nil, phoneReceivedAt: nil)
            }
        }
    }

    @discardableResult
    private func sendMessageInternal(
        _ message: String,
        teleopSequence: Int?,
        phoneReceivedAt: TimeInterval?
    ) -> Bool {
        guard let characteristic = controlCharacteristic,
              let device = connectedDevice,
              let data = message.data(using: .utf8) else {
            lastMessage = "Error: Not ready to send"
            if kEnableVerboseBleLogs {
                print("[BLE TX] dropped not-ready hasDevice=\(connectedDevice != nil) hasControlChar=\(controlCharacteristic != nil) msg=\"\(message)\"")
            }
            return false
        }

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        if kEnableVerboseBleLogs {
            let writeTypeLabel = (writeType == .withoutResponse) ? "withoutResponse" : "withResponse"
            print("[BLE TX] send msg=\"\(message)\" bytes=\(data.count) type=\(writeTypeLabel) char=\(characteristic.uuid) props=0x\(String(characteristic.properties.rawValue, radix: 16))")
        }
        device.writeValue(data, for: characteristic, type: writeType)
        let sentAt = Date().timeIntervalSince1970
        lastMessage = "Sent: \(message)"
        if kEnableVerboseBleLogs {
            print("[BLE TX] queued msg=\"\(message)\"")
        }

        if let motor = parseMotorCommand(message) {
            lastMotorCommandTimestamp = sentAt
            lastMotorLeftPercent = motor.left
            lastMotorRightPercent = motor.right
            lastMotorHoldMs = motor.durationMs
            lastMotorCommandText = "TX motor: \(motor.left) \(motor.right) \(motor.durationMs)"
            if let teleopSequence, let phoneReceivedAt {
                pendingTeleopTrace = PendingTeleopTrace(
                    seq: teleopSequence,
                    phoneReceivedAt: phoneReceivedAt,
                    bleDispatchedAt: sentAt,
                    leftPercent: motor.left,
                    rightPercent: motor.right,
                    holdMs: motor.durationMs
                )
            }
            return true
        }

        if let samplePeriodMs = parseSetPeriodCommand(message) {
            let clamped = max(1, min(1000, samplePeriodMs))
            latestOdomSamplePeriodMs = UInt16(clamped)
        }
        return true
    }

    func setOdometrySamplePeriod(samplePeriodMs: Int) {
        sendMessage("SET_PERIOD \(samplePeriodMs)")
    }

    func popWheelOdometrySample() -> WheelOdometrySample? {
        odomQueueLock.lock()
        defer { odomQueueLock.unlock() }
        guard !pendingOdomSamples.isEmpty else { return nil }
        return pendingOdomSamples.removeFirst()
    }

    func ensureWheelOdometryStreaming() {
        DispatchQueue.main.async { [weak self] in
            self?.activateOdometryStreamingIfPossible()
        }
    }

    private func enqueueWheelOdometrySamples(_ samples: [WheelOdometrySample]) {
        guard !samples.isEmpty else { return }
        odomQueueLock.lock()
        pendingOdomSamples.append(contentsOf: samples)
        let overflow = pendingOdomSamples.count - maxPendingOdomSamples
        if overflow > 0 {
            pendingOdomSamples.removeFirst(overflow)
        }
        odomQueueLock.unlock()
    }

    private func clearWheelOdometrySamples() {
        odomQueueLock.lock()
        pendingOdomSamples.removeAll(keepingCapacity: true)
        odomQueueLock.unlock()
    }

    private func activateOdometryStreamingIfPossible() {
        guard isConnected, let device = connectedDevice, let dataCharacteristic else { return }
        if dataCharacteristic.isNotifying || odomNotifyRequested {
            return
        }
        odomNotifyRequested = true
        device.setNotifyValue(true, for: dataCharacteristic)
    }

    private func decodeOdomFrame(_ data: Data) {
        guard data.count >= 3 else {
            if kEnableVerboseBleLogs {
                print("[BLE ODOM RX] frame too short bytes=\(data.count)")
            }
            return
        }

        let bytes = [UInt8](data)
        let seq = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let sampleCount = Int(bytes[2])
        let expectedLength = 3 + sampleCount * 4

        guard data.count == expectedLength else {
            if kEnableVerboseBleLogs {
                print("[BLE ODOM RX] frame length mismatch bytes=\(data.count) expected=\(expectedLength)")
            }
            return
        }

        if let previous = lastOdomSeq {
            let expected = previous &+ 1
            if seq != expected {
                if kEnableVerboseBleLogs {
                    print("[BLE ODOM RX] seq gap expected=\(expected) got=\(seq)")
                }
            }
        }
        lastOdomSeq = seq

        let samplePeriodSeconds = Double(latestOdomSamplePeriodMs) / 1000.0
        let baseTimestamp = Date().timeIntervalSince1970
        var samples: [WheelOdometrySample] = []
        samples.reserveCapacity(sampleCount)
        var offset = 3
        for idx in 0..<sampleCount {
            let dlRaw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let drRaw = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
            let dl = Int16(bitPattern: dlRaw)
            let dr = Int16(bitPattern: drRaw)
            samples.append(
                WheelOdometrySample(
                    timestamp: baseTimestamp + (Double(idx) * samplePeriodSeconds),
                    seq: Int32(seq),
                    dlTicks: Int32(dl),
                    drTicks: Int32(dr),
                    samplePeriodMs: Int32(latestOdomSamplePeriodMs)
                )
            )
            offset += 4
        }

        enqueueWheelOdometrySamples(samples)
        odomQueueLock.lock()
        let queuedCount = pendingOdomSamples.count
        odomQueueLock.unlock()

        let sumDl = samples.reduce(0) { $0 + Int($1.dlTicks) }
        let sumDr = samples.reduce(0) { $0 + Int($1.drTicks) }
        lastOdomFrameText = "RX odom: seq \(seq) n \(sampleCount) sum(\(sumDl),\(sumDr)) q=\(queuedCount)"

        let sinceMotorCommandMs = Int((Date().timeIntervalSince1970 - lastMotorCommandTimestamp) * 1000.0)
        if lastMotorCommandTimestamp > 0, sinceMotorCommandMs >= 0, sinceMotorCommandMs <= 2000 {
            lastMotorOdomText = "TX->RX: cmd(\(lastMotorLeftPercent),\(lastMotorRightPercent),\(lastMotorHoldMs)) -> ticks(\(sumDl),\(sumDr)) @\(sinceMotorCommandMs)ms"
        }
        resolvePendingTeleopTrace(frameArrivalAt: baseTimestamp, odomSeq: Int(seq), sumDl: sumDl, sumDr: sumDr)

        if let first = samples.first {
            // print("[BLE ODOM RX] frame seq=\(seq) n=\(sampleCount) dt_ms=\(latestOdomSamplePeriodMs) first=(\(first.dlTicks),\(first.drTicks)) queued=\(queuedCount)")
        } else {
            // print("[BLE ODOM RX] frame seq=\(seq) n=0 queued=\(queuedCount)")
        }

        lastMessage = "Odom seq=\(seq) n=\(sampleCount)"
    }

    private func isPreferredPeripheral(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name else { return false }
        return name.localizedCaseInsensitiveContains(preferredDeviceNameSubstring)
    }

    private func prunePendingTeleopTrace(now: TimeInterval) {
        guard let pendingTeleopTrace else { return }
        let ageMs = Int((now - pendingTeleopTrace.phoneReceivedAt) * 1000.0)
        guard ageMs > teleopMetricTimeoutMs else { return }
        lastTeleopLatencyText = "Teleop latency: timeout seq \(pendingTeleopTrace.seq)"
        WebSocketManager.shared.publishTeleopLatencyTimeout(seq: pendingTeleopTrace.seq)
        self.pendingTeleopTrace = nil
    }

    private func resolvePendingTeleopTrace(frameArrivalAt: TimeInterval, odomSeq: Int, sumDl: Int, sumDr: Int) {
        prunePendingTeleopTrace(now: frameArrivalAt)
        guard let pendingTeleopTrace else { return }
        guard sumDl != 0 || sumDr != 0 else { return }

        let phoneRxToBleMs = max(0, Int((pendingTeleopTrace.bleDispatchedAt - pendingTeleopTrace.phoneReceivedAt) * 1000.0))
        let bleToOdomMs = max(0, Int((frameArrivalAt - pendingTeleopTrace.bleDispatchedAt) * 1000.0))
        let phoneRxToOdomMs = max(0, Int((frameArrivalAt - pendingTeleopTrace.phoneReceivedAt) * 1000.0))
        let metric = TeleopLatencyMetric(
            seq: pendingTeleopTrace.seq,
            phoneRxToBleMs: phoneRxToBleMs,
            bleToOdomMs: bleToOdomMs,
            phoneRxToOdomMs: phoneRxToOdomMs,
            odomSeq: odomSeq,
            sumDlTicks: sumDl,
            sumDrTicks: sumDr,
            leftPercent: pendingTeleopTrace.leftPercent,
            rightPercent: pendingTeleopTrace.rightPercent,
            holdMs: pendingTeleopTrace.holdMs
        )
        lastTeleopLatencyText =
            "Teleop latency: seq \(metric.seq) rx->ble \(metric.phoneRxToBleMs)ms ble->odom \(metric.bleToOdomMs)ms total \(metric.phoneRxToOdomMs)ms"
        self.pendingTeleopTrace = nil
        WebSocketManager.shared.publishTeleopLatencyMetric(metric)
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionStatus = "Bluetooth Ready"
            if shouldStartScanningWhenReady {
                startScanning()
            }
        case .poweredOff:
            connectionStatus = "Bluetooth is Off"
        case .unauthorized:
            connectionStatus = "Bluetooth Unauthorized"
        case .unsupported:
            connectionStatus = "Bluetooth Not Supported"
        default:
            connectionStatus = "Unknown State"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            if isPreferredPeripheral(peripheral) {
                let firstNonPreferredIndex =
                    discoveredDevices.firstIndex(where: { !isPreferredPeripheral($0) }) ?? discoveredDevices.count
                discoveredDevices.insert(peripheral, at: firstNonPreferredIndex)
            } else {
                discoveredDevices.append(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedDevice = peripheral
        isConnected = true
        lastOdomSeq = nil
        latestOdomSamplePeriodMs = 20
        odomNotifyRequested = false
        lastMotorCommandText = "TX motor: -"
        lastOdomFrameText = "RX odom: -"
        lastMotorOdomText = "TX->RX: -"
        lastMotorCommandTimestamp = 0
        lastMotorLeftPercent = 0
        lastMotorRightPercent = 0
        lastMotorHoldMs = 0
        pendingTeleopTrace = nil
        teleopStopWatchdogToken += 1
        lastTeleopLatencyText = "Teleop latency: -"
        clearWheelOdometrySamples()
        connectionStatus = "Connected to \(peripheral.name ?? "Unknown")"
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedDevice = nil
        isConnected = false
        controlCharacteristic = nil
        dataCharacteristic = nil
        lastOdomSeq = nil
        latestOdomSamplePeriodMs = 20
        odomNotifyRequested = false
        lastMotorCommandText = "TX motor: -"
        lastOdomFrameText = "RX odom: -"
        lastMotorOdomText = "TX->RX: -"
        lastMotorCommandTimestamp = 0
        lastMotorLeftPercent = 0
        lastMotorRightPercent = 0
        lastMotorHoldMs = 0
        pendingTeleopTrace = nil
        teleopStopWatchdogToken += 1
        lastTeleopLatencyText = "Teleop latency: -"
        clearWheelOdometrySamples()
        connectionStatus = "Disconnected"
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Failed to Connect"
        if let error = error {
            if kEnableVerboseBleLogs {
                print("Connection error: \(error.localizedDescription)")
            }
        }
    }
}

private func parseMotorCommand(_ text: String) -> (left: Int, right: Int, durationMs: Int)? {
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    guard tokens.count == 3,
          let left = Int(tokens[0]),
          let right = Int(tokens[1]),
          let durationMs = Int(tokens[2]) else {
        return nil
    }
    return (left, right, durationMs)
}

private func parseSetPeriodCommand(_ text: String) -> Int? {
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    guard tokens.count == 2, String(tokens[0]) == "SET_PERIOD", let period = Int(tokens[1]) else {
        return nil
    }
    return period
}

// exported function for Wasm
func read_wheel_odometry_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }
    BluetoothManager.shared.ensureWheelOdometryStreaming()

    let sample = BluetoothManager.shared.popWheelOdometrySample() ??
        WheelOdometrySample(timestamp: 0.0, seq: -1, dlTicks: 0, drTicks: 0, samplePeriodMs: 0)

    let base = ptr.bindMemory(to: Double.self, capacity: 1)
    base[0] = sample.timestamp

    let intOffset = MemoryLayout<Double>.size
    ptr.advanced(by: intOffset).withMemoryRebound(to: Int32.self, capacity: 4) { ints in
        ints[0] = sample.seq
        ints[1] = sample.dlTicks
        ints[2] = sample.drTicks
        ints[3] = sample.samplePeriodMs
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([controlCharacteristicUUID, dataCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            if characteristic.uuid == controlCharacteristicUUID {
                controlCharacteristic = characteristic
                if kEnableVerboseBleLogs {
                    print("Control characteristic discovered")
                }
            } else if characteristic.uuid == dataCharacteristicUUID {
                dataCharacteristic = characteristic
                if kEnableVerboseBleLogs {
                    print("Data characteristic discovered")
                }
            }
        }

        activateOdometryStreamingIfPossible()

        if controlCharacteristic != nil {
            connectionStatus = (dataCharacteristic?.isNotifying == true) ? "Ready + Odom Notify" : "Ready"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid != dataCharacteristicUUID {
            return
        }

        odomNotifyRequested = false

        if let error = error {
            if kEnableVerboseBleLogs {
                print("Failed to subscribe to odometry notifications: \(error.localizedDescription)")
            }
            return
        }

        if characteristic.isNotifying {
            if kEnableVerboseBleLogs {
                print("Notifications enabled for \(characteristic.uuid)")
            }
            connectionStatus = "Ready + Odom Notify"
        } else {
            if kEnableVerboseBleLogs {
                print("Notifications disabled for \(characteristic.uuid)")
            }
            activateOdometryStreamingIfPossible()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            lastMessage = "Send Error: \(error.localizedDescription)"
            if kEnableVerboseBleLogs {
                print("[BLE TX] write error char=\(characteristic.uuid) err=\(error.localizedDescription)")
            }
        } else if kEnableVerboseBleLogs {
            print("[BLE TX] write ack char=\(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            if kEnableVerboseBleLogs {
                print("Error receiving data: \(error.localizedDescription)")
            }
            return
        }

        guard let data = characteristic.value else {
            if kEnableVerboseBleLogs {
                print("No data received")
            }
            return
        }

        if characteristic.uuid == dataCharacteristicUUID {
            decodeOdomFrame(data)
            return
        }

        if let response = String(data: data, encoding: .utf8) {
            lastMessage = "Received: \(response)"
            if kEnableVerboseBleLogs {
                print("Received response: \(response)")
            }
        } else if kEnableVerboseBleLogs {
            print("Received data (hex): \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
    }
}
