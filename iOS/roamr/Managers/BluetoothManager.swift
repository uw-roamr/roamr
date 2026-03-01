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
    @Published var lastSentMessage = ""
    @Published var lastReceivedMessage = ""

    private var centralManager: CBCentralManager!
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var shouldStartScanningWhenReady = false

    private var lastOdomSeq: UInt16?
    private var latestOdomSamplePeriodMs: UInt16 = 20
    private let odomQueueLock = NSLock()
    private var pendingOdomSamples: [WheelOdometrySample] = []
    private let maxPendingOdomSamples = 12_000

    // UUIDs matching ESP32 firmware
    private let serviceUUID = CBUUID(string: "00FF")
    private let controlCharacteristicUUID = CBUUID(string: "FF01")
    private let dataCharacteristicUUID = CBUUID(string: "FF02")
    private let statusCharacteristicUUID = CBUUID(string: "FF03")

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
            lastSentMessage = "Error: Not ready to send"
            lastMessage = "Sent: \(lastSentMessage)"
            return
        }

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        device.writeValue(data, for: characteristic, type: writeType)
        lastSentMessage = message
        lastMessage = "Sent: \(message)"
        print("Sent: \(message)")
    }

    func startOdometry(durationMs: Int, samplePeriodMs: Int = 20) {
        sendMessage("START \(durationMs) \(samplePeriodMs)")
    }

    func stopOdometry() {
        sendMessage("STOP")
    }

    func clearOdometry() {
        sendMessage("CLEAR")
    }

    func requestOdometryStatus() {
        if let device = connectedDevice, let statusCharacteristic {
            device.readValue(for: statusCharacteristic)
        }
        sendMessage("GET_STATUS")
    }

    func popWheelOdometrySample() -> WheelOdometrySample? {
        odomQueueLock.lock()
        defer { odomQueueLock.unlock() }
        guard !pendingOdomSamples.isEmpty else { return nil }
        return pendingOdomSamples.removeFirst()
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

    private func decodeOdomFrame(_ data: Data) {
        guard data.count >= 3 else {
            print("Odom frame too short: \(data.count)")
            return
        }

        let bytes = [UInt8](data)
        let seq = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let sampleCount = Int(bytes[2])
        let expectedLength = 3 + sampleCount * 4

        guard data.count == expectedLength else {
            print("Odom frame length mismatch: got=\(data.count) expected=\(expectedLength)")
            return
        }

        if let previous = lastOdomSeq {
            let expected = previous &+ 1
            if seq != expected {
                print("Odom seq gap: expected=\(expected) got=\(seq)")
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

        if let first = samples.first {
            print("Odom frame seq=\(seq) n=\(sampleCount) first=(\(first.dlTicks), \(first.drTicks))")
        } else {
            print("Odom frame seq=\(seq) n=0")
        }

        lastReceivedMessage = "Odom seq=\(seq) n=\(sampleCount)"
        lastMessage = "Received: \(lastReceivedMessage)"
    }

    private func decodeOdomStatus(_ data: Data) {
        guard data.count >= 9 else {
            print("Odom status too short: \(data.count)")
            return
        }

        let bytes = [UInt8](data)
        let state = bytes[0]
        let buffered = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        let dropped = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
        let lastSeq = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)
        let samplePeriodMs = UInt16(bytes[7]) | (UInt16(bytes[8]) << 8)
        latestOdomSamplePeriodMs = samplePeriodMs

        let stateName: String
        switch state {
        case 0: stateName = "IDLE"
        case 1: stateName = "RECORDING"
        case 2: stateName = "UPLOADING"
        default: stateName = "UNKNOWN(\(state))"
        }

        lastReceivedMessage = "Status: \(stateName) buffered=\(buffered) dropped=\(dropped) last_seq=\(lastSeq) dt=\(samplePeriodMs)ms"
        lastMessage = "Received: \(lastReceivedMessage)"
        print("Odom status state=\(stateName) buffered=\(buffered) dropped=\(dropped) last_seq=\(lastSeq) dt=\(samplePeriodMs)ms")
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
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedDevice = peripheral
        isConnected = true
        lastOdomSeq = nil
        latestOdomSamplePeriodMs = 20
        clearWheelOdometrySamples()
        lastSentMessage = ""
        lastReceivedMessage = ""
        connectionStatus = "Connected to \(peripheral.name ?? "Unknown")"
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedDevice = nil
        isConnected = false
        controlCharacteristic = nil
        dataCharacteristic = nil
        statusCharacteristic = nil
        lastOdomSeq = nil
        latestOdomSamplePeriodMs = 20
        clearWheelOdometrySamples()
        lastSentMessage = ""
        lastReceivedMessage = ""
        connectionStatus = "Disconnected"
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Failed to Connect"
        if let error = error {
            print("Connection error: \(error.localizedDescription)")
        }
    }
}

// exported function for Wasm
func read_wheel_odometry_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

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

        for service in services {
            peripheral.discoverCharacteristics([controlCharacteristicUUID, dataCharacteristicUUID, statusCharacteristicUUID], for: service)
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
                peripheral.setNotifyValue(true, for: characteristic)
                print("Data characteristic discovered (subscribing)")
            } else if characteristic.uuid == statusCharacteristicUUID {
                statusCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                print("Status characteristic discovered")
            }
        }

        if controlCharacteristic != nil {
            connectionStatus = "Ready"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Failed to subscribe to notifications: \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            print("Notifications enabled for \(characteristic.uuid)")
            connectionStatus = "Ready + Odom Notify"
        } else {
            print("Notifications disabled for \(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            lastSentMessage = "Error: \(error.localizedDescription)"
            lastMessage = "Sent: \(lastSentMessage)"
            print("Write error: \(error.localizedDescription)")
        } else {
            print("Write successful for characteristic: \(characteristic.uuid)")
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

        if characteristic.uuid == statusCharacteristicUUID {
            decodeOdomStatus(data)
            return
        }

        if let response = String(data: data, encoding: .utf8) {
            print("Received response: \(response)")
            lastReceivedMessage = response
            lastMessage = "Received: \(response)"
        } else {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("Received data (hex): \(hex)")
            lastReceivedMessage = "hex: \(hex)"
            lastMessage = "Received: \(lastReceivedMessage)"
        }
    }
}
