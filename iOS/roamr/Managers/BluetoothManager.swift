//
//  BluetoothManager.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-22.
//

import Foundation
import CoreBluetooth
import Combine

class BluetoothManager: NSObject, ObservableObject {
    static let shared = BluetoothManager()

    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectionStatus = "Not Connected"
    @Published var lastMessage = ""

    private var centralManager: CBCentralManager!
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var shouldStartScanningWhenReady = false

    private var lastOdomSeq: UInt16?

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
            lastMessage = "Error: Not ready to send"
            return
        }

        device.writeValue(data, for: characteristic, type: .withoutResponse)
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

        var samples: [(Int16, Int16)] = []
        samples.reserveCapacity(sampleCount)

        var offset = 3
        for _ in 0..<sampleCount {
            let dlRaw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let drRaw = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
            let dl = Int16(bitPattern: dlRaw)
            let dr = Int16(bitPattern: drRaw)
            samples.append((dl, dr))
            offset += 4
        }

        if let first = samples.first {
            print("Odom frame seq=\(seq) n=\(sampleCount) first=(\(first.0), \(first.1))")
        } else {
            print("Odom frame seq=\(seq) n=0")
        }

        lastMessage = "Odom seq=\(seq) n=\(sampleCount)"
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

        let stateName: String
        switch state {
        case 0: stateName = "IDLE"
        case 1: stateName = "RECORDING"
        case 2: stateName = "UPLOADING"
        default: stateName = "UNKNOWN(\(state))"
        }

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
        connectionStatus = "Disconnected"
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Failed to Connect"
        if let error = error {
            print("Connection error: \(error.localizedDescription)")
        }
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
            lastMessage = "Send Error: \(error.localizedDescription)"
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
            lastMessage = "Received: \(response)"
        } else {
            print("Received data (hex): \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
    }
}
