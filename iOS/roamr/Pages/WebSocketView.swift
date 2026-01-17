//
//  WebSocketView.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-23.
//

import SwiftUI

struct WebSocketView: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @StateObject private var serverManager = WebSocketManager()
    @EnvironmentObject var bluetoothManager: BluetoothManager

    var body: some View {
        VStack(spacing: 20) {
			PageHeader(
				title: "WebSocket",
				statusText: serverManager.serverStatus,
				statusColor: serverManager.isServerRunning ? .green : .orange
			) {
				Button {
					if serverManager.isServerRunning {
						serverManager.stopServer()
					} else {
						serverManager.startServer()
					}
				} label: {
					PlayButton(isActive: serverManager.isServerRunning)
				}
			}

            // Server Details
            if serverManager.isServerRunning {
				VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("IP Address:")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Spacer()
                            Text(serverManager.localIPAddress)
                                .font(.headline)
                                .fontWeight(.bold)
                                .textSelection(.enabled)
                        }

                        HStack {
                            Text("Port:")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Spacer()
                            Text("8080")
                                .font(.headline)
                                .fontWeight(.bold)
                        }

                        HStack {
                            Text("Connected Clients:")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(serverManager.connectedClients)")
                                .font(.headline)
                                .fontWeight(.bold)
                        }

                        Divider()
							.padding(.vertical, 8)

                        Text("Connect from web browser:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("ws://\(serverManager.localIPAddress):8080")
                            .font(.system(.body, design: .monospaced))
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)

				// Last Message
				if !serverManager.lastMessage.isEmpty {
					VStack(alignment: .leading, spacing: 8) {
						Text("Last Message Received:")
							.font(.headline)

						Text(serverManager.lastMessage)
							.font(.system(.body, design: .monospaced))
							.padding()
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(Color(.systemGray6))
							.cornerRadius(10)
					}
					.padding(.horizontal)
				}
            } else {
				Spacer()

				VStack(spacing: 16) {
					Image(systemName: "network")
						.font(.system(size: 48))
						.foregroundColor(.gray.opacity(0.5))

					Text("Monitor roamr")
						.font(.headline)
						.foregroundColor(.gray)

					Text("Start the WebSocket server and connect to monitor roamr from your computer")
						.font(.caption)
						.foregroundColor(.gray.opacity(0.7))
						.multilineTextAlignment(.center)
						.padding(.horizontal, 40)
				}
				.padding(.bottom, AppConstants.shared.tabBarHeight)
			}

            Spacer()
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom)
        .onAppear {
            serverManager.bluetoothManager = bluetoothManager
        }
    }
}
