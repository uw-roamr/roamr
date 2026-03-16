//
//  ContentView.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//

import SwiftUI

struct ContentView: View {
	@State var currentPage: AppPage = .wasm

	var body: some View {
		ZStack(alignment: .bottom) {
			Group {
				switch currentPage {
				case .wasm:
					WasmHubView()
				case .camera:
					CameraDepthView()
				case .bluetooth:
					BluetoothView()
						.environmentObject(BluetoothManager.shared)
				case .websocket:
					WebSocketView()
						.environmentObject(BluetoothManager.shared)
				case .settings:
					SettingsPage()
				}
			}
			.ignoresSafeArea()
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.animation(.easeInOut, value: currentPage)

			FloatingBubbleTabBar(currentPage: $currentPage)
				.padding(.bottom, 12)
				.zIndex(1)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
