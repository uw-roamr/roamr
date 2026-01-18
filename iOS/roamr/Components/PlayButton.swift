//
//  PlayButton.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI

struct PlayButton: View {
	var color: Color = Color.AppColor.accent.color
	var isActive: Bool = false
	var iconName: String? = nil
	var fontSize: CGFloat = 20
	var size: CGFloat = 50

	private var resolvedIconName: String {
		iconName ?? (isActive ? "stop.fill" : "play.fill")
	}

	var body: some View {
		ZStack {
			if isActive {
				Circle()
					.fill(.ultraThinMaterial)
					.frame(width: size, height: size)
			} else {
				Circle()
					.fill(color)
					.frame(width: size, height: size)
			}

			Image(systemName: resolvedIconName)
				.foregroundColor(.white)
				.font(.system(size: fontSize, weight: .semibold))
		}
	}
}
