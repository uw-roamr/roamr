//
//  MotorBridge.swift
//  roamr
//
//  Exposes a simple motor write primitive to WASM.
//

import Foundation

// Keep layout in sync with WASM/motors.h
struct MotorCommand {
    var left_percent: Int32
    var right_percent: Int32
    var hold_ms: Int32
}

// Simple watchdog to enforce hold_ms on the iOS side (BLE target currently ignores it).
private let motorQueue = DispatchQueue(label: "com.roamr.motorbridge")
private var lastCommandToken = 0
private let enableVerboseMotorHostLogging = false

func write_motors_impl(exec_env: wasm_exec_env_t?, ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }

    let command = ptr.bindMemory(to: MotorCommand.self, capacity: 1).pointee

    let clampedLeft = max(-100, min(100, Int(command.left_percent)))
    let clampedRight = max(-100, min(100, Int(command.right_percent)))
    let holdMs = max(0, Int(command.hold_ms))

    let message = "\(clampedLeft) \(clampedRight) \(holdMs)"
    if enableVerboseMotorHostLogging {
        WasmManager.shared.appendLogLine("[host][motor] \(message)")
    }

    motorQueue.async {
        // Bump token for each command; used to cancel stale watchdogs.
        lastCommandToken += 1
        let token = lastCommandToken

        DispatchQueue.main.async {
            BluetoothManager.shared.sendMessage(message)
        }

        guard holdMs > 0 else { return }

        motorQueue.asyncAfter(deadline: .now() + .milliseconds(holdMs)) {
            // Only send stop if no newer command has been issued
            guard token == lastCommandToken else { return }
            DispatchQueue.main.async {
                BluetoothManager.shared.sendMessage("0 0 0")
            }
        }
    }
}
