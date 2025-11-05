//
//  Color+Extensions.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI

extension Color {
	enum AppColor: String, CaseIterable {
//		case primary
//		case secondary
		case accent
		case background
//		case textPrimary
//		case textSecondary
		
		/// Returns a SwiftUI `Color` loaded from Assets.xcassets
		var color: Color {
			Color(self.rawValue)
		}
	}
}
