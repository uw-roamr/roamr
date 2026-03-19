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
    @AppStorage("bluetoothMaxCommand") private var maxCommand: Double = 50
    @State private var isSettingsPresented = false

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
                        JoystickView(maxCommand: maxCommand, onSettingsTapped: { isSettingsPresented = true }) { left, right, duration in
                            let message = "\(left) \(right) \(duration)"
                            bluetoothManager.sendMessage(message)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(bluetoothManager.lastMotorCommandText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(bluetoothManager.lastOdomFrameText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(bluetoothManager.lastMotorOdomText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
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
        .onChange(of: bluetoothManager.isConnected) { _, connected in
            if !connected {
                isSettingsPresented = false
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    HStack {
                        Text("Max Power")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(maxCommand.rounded()))%")
                            .font(.headline.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $maxCommand, in: 10...100, step: 5)
                        .tint(.blue)
                    Text("Scales the joystick output sent to the ESP. At 100% the full ±100 range is used.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))

                Spacer()
            }
            .padding()
            .presentationDetents([.fraction(0.3)])
            .presentationDragIndicator(.visible)
        }
    }
}
