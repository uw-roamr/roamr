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
	@Binding var currentPage: AppPage
	
	var body: some View {
		HStack(spacing: 30) {
			TabBubble(page: .ARView, currentPage: $currentPage)
//			TabBubble(page: .data, currentPage: $currentPage)
//				.scaleEffect(currentPage == .ARView ? 1 : 0.1)
//				.opacity(currentPage == .ARView ? 1 : 0)
//				.frame(width: currentPage == .ARView ? 40 : 0, height: currentPage == .ARView ? 40 : 0)
//				.animation(.spring(response: 0.1, dampingFraction: 0.9), value: currentPage)
			
			if currentPage == .ARView {
					TabBubble(page: .data, currentPage: $currentPage)
						.transition(.scale.combined(with: .opacity))
				}
			
			TabBubble(page: .settings, currentPage: $currentPage)
		}
		.padding(12)
		.background(
			Capsule()
				.fill(Color(.systemBackground).opacity(0.9))
				.shadow(color: .black.opacity(0.15), radius: 10, y: 5)
		)
		.frame(maxHeight: .infinity, alignment: .bottom)
		.animation(.spring(), value: currentPage)
	}
}

struct TabBubble: View {
	let page: AppPage
	@Binding var currentPage: AppPage
	
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
			currentPage = page
		} label: {
			Icon(color: isActive ? Color.AppColor.accent.color : Color.gray.opacity(0.2), iconName: page.iconName, fontSize: fontSize, size: circleSize)
				.shadow(color: isActive ? Color("AccentColor").opacity(0.4) : .clear, radius: 6, y: 3)
		}
		.buttonStyle(.plain)
		.scaleEffect(scale)
		.animation(.spring(response: 0.4, dampingFraction: 0.7), value: isActive)
	}
}
