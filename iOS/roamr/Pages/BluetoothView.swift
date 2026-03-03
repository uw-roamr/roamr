//
//  BluetoothPage.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-22.
//

import SwiftUI

struct BluetoothView: View {
	@Environment(\.safeAreaInsets) private var safeAreaInsets

	@EnvironmentObject private var bluetoothManager: BluetoothManager

    var body: some View {
        VStack {
			PageHeader(
				title: "Bluetooth",
				statusText: bluetoothManager.connectionStatus,
				statusColor: bluetoothManager.isConnected ? .green : .orange
			) {
				Button {
					bluetoothManager.disconnect()
				} label: {
					PlayButton(color: bluetoothManager.isConnected ? Color.red : Color.gray, iconName: "xmark")
				}
				.disabled(!bluetoothManager.isConnected)
				.opacity(bluetoothManager.isConnected ? 1 : 0)
			}

            // Scan Button
            if !bluetoothManager.isConnected {
				List {
					ForEach(bluetoothManager.discoveredDevices, id: \.identifier) { device in
						Button(action: {
							bluetoothManager.connect(to: device)
						}) {
							HStack {
								Image(systemName: "antenna.radiowaves.left.and.right")
									.foregroundColor(.blue)
								VStack(alignment: .leading) {
									Text(device.name ?? "Unknown Device")
										.font(.headline)
									Text(device.identifier.uuidString)
										.font(.caption)
										.foregroundColor(.gray)
								}
								Spacer()
								Image(systemName: "chevron.right")
									.foregroundColor(.gray)
							}
						}
					}
				}
				.listStyle(.plain)
				.scrollContentBackground(.hidden)
            } else {
				// DEVICE CONNECTED
                VStack(spacing: 20) {
                    Spacer()

                    // Joystick Control
					VStack(spacing: 15) {
                        JoystickView { left, right, duration in
                            let message = "\(left) \(right) \(duration)"
                            bluetoothManager.sendMessage(message)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(bluetoothManager.lastMotorCommandText)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(bluetoothManager.lastOdomFrameText)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(bluetoothManager.lastMotorOdomText)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                    }

                    Spacer()

					Text(bluetoothManager.lastMessage.isEmpty ? " " : bluetoothManager.lastMessage)
						.font(.caption2)
						.foregroundColor(.gray)
						.lineLimit(1)
						.truncationMode(.middle)
						.padding()
                }
				.padding(.bottom, AppConstants.shared.tabBarHeight)
            }
        }
		.padding(.top, safeAreaInsets.top)
		.padding(.bottom, safeAreaInsets.bottom)
		.onAppear {
			bluetoothManager.startScanning()
		}
    }
}
