//
//  ContentView.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//

import SwiftUI

struct ContentView: View {
	@StateObject private var bluetoothManager = BluetoothManager()
	@State var currentPage: AppPage = .wasm

	var body: some View {
		VStack {
			ZStack {
				Group {
					switch currentPage {
					case .wasm:
						WasmHubView()
					case .camera:
						CameraDepthView()
					case .bluetooth:
						BluetoothView()
					case .websocket:
						WebSocketView()
					case .settings:
						SettingsPage()
					}
				}
				.ignoresSafeArea()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.animation(.easeInOut, value: currentPage)

				VStack {
					Spacer()

					FloatingBubbleTabBar(currentPage: $currentPage)
				}
			}
		}
		.environmentObject(bluetoothManager)
	}
}
