//
//  ContentView.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//

import SwiftUI

struct ContentView: View {
	@EnvironmentObject var lidarManager: LiDARManager
	let server = WebSocketServerManager()
	@State var currentPage: AppPage = .ARView

	struct SettingsPage: View {
		var body: some View {
			Color.orange.opacity(0.1)
				.overlay(Text("⚙️ Settings").font(.largeTitle))
				.ignoresSafeArea()
		}
	}

	var body: some View {
		VStack {
			ZStack {
				Group {
					switch currentPage {
					case .ARView:
						LiDARView()
					case .data:
						DataView()
					case .settings:
						SettingsPage()
					}
				}
				.ignoresSafeArea()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.animation(.easeInOut, value: currentPage)
				
				FloatingBubbleTabBar(currentPage: $currentPage)
			}
			
//			LiDARView()
//				.edgesIgnoringSafeArea(.all)
//				.onAppear {
//					lidarManager.startSession()
//				}

//			VStack(spacing: 16) {
//				Text("LiDAR → Console")
//					.font(.title)
//
//				VStack {
//					Button("Start Server") {
//						server.start()
//					}
//					
//					Button("Start WebPage") {
//						showWebPage.toggle()
//					}
//					
//					Button("Send Message to Web Page") {
//						server.broadcast("Hello from SwiftUI 🚀")
//					}
//				}
//				.padding()
//				
//				if showWebPage {
//					WebView(fileName: "index")
//				}
//
//				Spacer()
//			}
//			.padding()
		}
	}
}
