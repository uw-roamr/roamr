//
//  TabBar.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI

enum AppPage {
	case wasm
	case camera
	case settings
	case bluetooth
	case websocket

	var iconName: String {
		switch self {
		case .wasm: return "scroll.fill"
		case .camera: return "camera.viewfinder"
		case .bluetooth: return "antenna.radiowaves.left.and.right"
		case .settings: return "gearshape.fill"
		case .websocket: return "network"
		}
	}
}

struct FloatingBubbleTabBar: View {
	@Binding var currentPage: AppPage

	var body: some View {
		HStack(spacing: 30) {
			TabBubble(page: .wasm, currentPage: $currentPage)

			TabBubble(page: .camera, currentPage: $currentPage)

			TabBubble(page: .bluetooth, currentPage: $currentPage)

			TabBubble(page: .websocket, currentPage: $currentPage)

			TabBubble(page: .settings, currentPage: $currentPage)
		}
		.padding(12)
		.background(
			GeometryReader { geo in
				Capsule()
					.fill(.ultraThinMaterial)
					.shadow(color: .black.opacity(0.15), radius: 10, y: 5)
					.onAppear {
						AppConstants.shared.tabBarHeight = geo.size.height
					}
			}
		)
		.animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentPage)
	}
}

struct TabBubble: View {
	let page: AppPage
	@Binding var currentPage: AppPage
	var closure: (() -> Void)?

	var isActive: Bool { currentPage == page }

	var backgroundColor: Color {
		isActive ? Color("AccentColor") : Color.gray.opacity(0.2)
	}

	var scale: CGFloat {
		isActive ? 1.1 : 1.0
	}

	var circleSize: CGFloat {
		isActive ? 50 : 40
	}

	var fontSize: CGFloat {
		isActive ? 20 : 18
	}

	var body: some View {
		Button {
			if let closure {
				closure()
			} else {
				currentPage = page
			}
		} label: {
			PlayButton(color: isActive ? Color.AppColor.accent.color : Color.gray.opacity(0.2), iconName: page.iconName, fontSize: fontSize, size: circleSize)
				.shadow(color: isActive ? Color("AccentColor").opacity(0.4) : .clear, radius: 6, y: 3)
		}
		.buttonStyle(.plain)
		.scaleEffect(scale)
		.animation(.spring(response: 0.4, dampingFraction: 0.7), value: isActive)
	}
}
