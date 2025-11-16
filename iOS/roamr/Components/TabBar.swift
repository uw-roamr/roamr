//
//  TabBar.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI

enum AppPage {
	case ARView
	case data
	case settings

	var iconName: String {
		switch self {
		case .ARView: return "macbook.and.vision.pro"
		case .data: return "text.page.fill"
		case .settings: return "gearshape.fill"
		}
	}
}

struct FloatingBubbleTabBar: View {
	@EnvironmentObject var lidarManager: LiDARManager
	@Binding var currentPage: AppPage

	var body: some View {
		HStack(spacing: 30) {
			TabBubble(page: .ARView, currentPage: $currentPage)

			if currentPage == .ARView {
				TabBubble(page: .data, currentPage: $currentPage) {
					withAnimation {
						lidarManager.showDataSheet.toggle()
					}
				}
				.transition(.scale.combined(with: .opacity))
			}

			TabBubble(page: .settings, currentPage: $currentPage)
		}
		.padding(12)
		.background(
			Capsule()
				.fill(.ultraThinMaterial)
				.shadow(color: .black.opacity(0.15), radius: 10, y: 5)
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
			Icon(color: isActive ? Color.AppColor.accent.color : Color.gray.opacity(0.2), iconName: page.iconName, fontSize: fontSize, size: circleSize)
				.shadow(color: isActive ? Color("AccentColor").opacity(0.4) : .clear, radius: 6, y: 3)
		}
		.buttonStyle(.plain)
		.scaleEffect(scale)
		.animation(.spring(response: 0.4, dampingFraction: 0.7), value: isActive)
	}
}
