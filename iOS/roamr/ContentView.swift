//
//  ContentView.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//

import SwiftUI

struct ContentView: View {
	@EnvironmentObject var lidarManager: LiDARManager
	@State var currentPage: AppPage = .ARView

	var body: some View {
		VStack {
			ZStack {
				Group {
					switch currentPage {
					case .ARView:
						LiDARView()
					case .data:
						EmptyView()
					case .settings:
						SettingsPage()
					}
				}
				.ignoresSafeArea()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.animation(.easeInOut, value: currentPage)

				VStack {
					Spacer()

					if lidarManager.showDataSheet {
						DataView()
							.transition(.scale.combined(with: .opacity))
							.animation(.easeInOut(duration: 0.13), value: lidarManager.showDataSheet)
					}

					FloatingBubbleTabBar(currentPage: $currentPage)
				}
			}
		}
	}
}
