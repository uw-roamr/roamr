//
//  BluetoothPage.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-22.
//

import SwiftUI
import CoreBluetooth

struct BluetoothView: View {
	@Environment(\.safeAreaInsets) private var safeAreaInsets

	@EnvironmentObject private var bluetoothManager: BluetoothManager
    @State private var messageToSend = ""

    var body: some View {
        VStack(spacing: 20) {
			HStack {
				Button(action: {
				}) {
					Icon(color: bluetoothManager.isConnected ? Color.red : Color.gray, iconName: "xmark")
				}
				.padding(.horizontal)
				.disabled(true)
				.opacity(0)

				// Status
				VStack(spacing: 8) {
					Text(bluetoothManager.connectionStatus)
						.font(.headline)
						.foregroundColor(bluetoothManager.isConnected ? .green : .orange)

					if !bluetoothManager.lastMessage.isEmpty {
						Text(bluetoothManager.lastMessage)
							.font(.caption)
							.foregroundColor(.gray)
					}
				}
				.padding()
				.background(Color(.systemGray6))
				.cornerRadius(20)
				.padding(.horizontal)
				.frame(maxWidth: .infinity)

				// Disconnect Button
				Button(action: {
					bluetoothManager.disconnect()
				}) {
					Icon(color: bluetoothManager.isConnected ? Color.red : Color.gray, iconName: "xmark")
				}
				.padding(.horizontal)
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
				.listStyle(InsetGroupedListStyle())
            } else {
				// DEVICE CONNECTED
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                        Text("Connected to")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(bluetoothManager.connectedDevice?.name ?? "Unknown Device")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .padding()

                    // Joystick Control
					VStack(spacing: 15) {
                        JoystickView { left, right, duration in
                            let message = "\(left) \(right) \(duration)"
							// print(message)
                            bluetoothManager.sendMessage(message)
                        }
                    }

                    Spacer()
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
