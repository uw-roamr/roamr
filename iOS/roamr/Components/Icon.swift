//
//  Icon.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI

struct Icon: View {
	var color: Color
	var iconName: String
	var fontSize: CGFloat = 20
	var size: CGFloat = 50
	
	var body: some View {
		ZStack {
			Circle()
				.fill(color)
				.frame(width: size, height: size)
			
			Image(systemName: iconName)
				.foregroundColor(.white)
				.font(.system(size: fontSize, weight: .semibold))
		}
	}
}
