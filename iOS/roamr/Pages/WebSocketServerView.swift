//
//  WebSocketServerView.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-23.
//

import SwiftUI

struct WebSocketServerView: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @StateObject private var serverManager = WebSocketServerManager()
    @EnvironmentObject var bluetoothManager: BluetoothManager

    var body: some View {
        VStack(spacing: 20) {
            // Header
			HStack {
				Text("WebSocket")
					.font(.largeTitle)
					.fontWeight(.bold)
					.padding()

				Spacer()

				// Server Control Button
				Button(action: {
					if serverManager.isServerRunning {
						serverManager.stopServer()
					} else {
						serverManager.startServer()
					}
				}) {
					HStack {
						Icon(color: serverManager.isServerRunning ? Color.red : Color.green, iconName: serverManager.isServerRunning ? "stop.fill" : "play.fill")
					}
					.padding()
				}
				.padding(.horizontal)
			}

            // Server Status
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(serverManager.isServerRunning ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                    Text(serverManager.serverStatus)
                        .font(.headline)
                }

                if serverManager.isServerRunning {
                    VStack(spacing: 8) {
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

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect from web browser:")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text("ws://\(serverManager.localIPAddress):8080")
                                .font(.system(.body, design: .monospaced))
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                                .textSelection(.enabled)
                        }
                    }
                }
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

            Spacer()
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom)
        .onAppear {
            serverManager.bluetoothManager = bluetoothManager
        }
    }
}
