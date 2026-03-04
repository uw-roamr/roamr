//
//  BluetoothManager.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-22.
//

import Foundation
import CoreBluetooth
import Combine

struct WheelOdometrySample {
    var timestamp: Double
    var seq: Int32
    var dlTicks: Int32
    var drTicks: Int32
    var samplePeriodMs: Int32
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
    private let odomQueueLock = NSLock()
    private var pendingOdomSamples: [WheelOdometrySample] = []
    private let maxPendingOdomSamples = 12_000
    private let preferredDeviceNameSubstring = "ESP32_C6"

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
        guard let characteristic = controlCharacteristic,
              let device = connectedDevice,
              let data = message.data(using: .utf8) else {
            lastMessage = "Error: Not ready to send"
            print("[BLE TX] dropped not-ready hasDevice=\(connectedDevice != nil) hasControlChar=\(controlCharacteristic != nil) msg=\"\(message)\"")
            return
        }

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let writeTypeLabel = (writeType == .withoutResponse) ? "withoutResponse" : "withResponse"
        print("[BLE TX] send msg=\"\(message)\" bytes=\(data.count) type=\(writeTypeLabel) char=\(characteristic.uuid) props=0x\(String(characteristic.properties.rawValue, radix: 16))")
        device.writeValue(data, for: characteristic, type: writeType)
        lastMessage = "Sent: \(message)"
        print("[BLE TX] queued msg=\"\(message)\"")

        if let motor = parseMotorCommand(message) {
            lastMotorCommandTimestamp = Date().timeIntervalSince1970
            lastMotorLeftPercent = motor.left
            lastMotorRightPercent = motor.right
            lastMotorHoldMs = motor.durationMs
            lastMotorCommandText = "TX motor: \(motor.left) \(motor.right) \(motor.durationMs)"
            return
        }

        if let samplePeriodMs = parseSetPeriodCommand(message) {
            let clamped = max(1, min(1000, samplePeriodMs))
            latestOdomSamplePeriodMs = UInt16(clamped)
        }
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
            print("[BLE ODOM RX] frame too short bytes=\(data.count)")
            return
        }

        let bytes = [UInt8](data)
        let seq = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let sampleCount = Int(bytes[2])
        let expectedLength = 3 + sampleCount * 4

        guard data.count == expectedLength else {
            print("[BLE ODOM RX] frame length mismatch bytes=\(data.count) expected=\(expectedLength)")
            return
        }

        if let previous = lastOdomSeq {
            let expected = previous &+ 1
            if seq != expected {
                print("[BLE ODOM RX] seq gap expected=\(expected) got=\(seq)")
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

        if let first = samples.first {
            print("[BLE ODOM RX] frame seq=\(seq) n=\(sampleCount) dt_ms=\(latestOdomSamplePeriodMs) first=(\(first.dlTicks),\(first.drTicks)) queued=\(queuedCount)")
        } else {
            print("[BLE ODOM RX] frame seq=\(seq) n=0 queued=\(queuedCount)")
        }

        lastMessage = "Odom seq=\(seq) n=\(sampleCount)"
    }

    private func isPreferredPeripheral(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name else { return false }
        return name.localizedCaseInsensitiveContains(preferredDeviceNameSubstring)
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
        clearWheelOdometrySamples()
        connectionStatus = "Disconnected"
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Failed to Connect"
        if let error = error {
            print("Connection error: \(error.localizedDescription)")
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
                print("Control characteristic discovered")
            } else if characteristic.uuid == dataCharacteristicUUID {
                dataCharacteristic = characteristic
                print("Data characteristic discovered")
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
            print("Failed to subscribe to odometry notifications: \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            print("Notifications enabled for \(characteristic.uuid)")
            connectionStatus = "Ready + Odom Notify"
        } else {
            print("Notifications disabled for \(characteristic.uuid)")
            activateOdometryStreamingIfPossible()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            lastMessage = "Send Error: \(error.localizedDescription)"
            print("[BLE TX] write error char=\(characteristic.uuid) err=\(error.localizedDescription)")
        } else {
            print("[BLE TX] write ack char=\(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error receiving data: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else {
            print("No data received")
            return
        }

        if characteristic.uuid == dataCharacteristicUUID {
            decodeOdomFrame(data)
            return
        }

        if let response = String(data: data, encoding: .utf8) {
            print("Received response: \(response)")
            lastMessage = "Received: \(response)"
        } else {
            print("Received data (hex): \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
    }
}
