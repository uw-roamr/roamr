//
//  AppConstants.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-23.
//

import SwiftUI

@Observable
class AppConstants {
	static let shared = AppConstants()

	var tabBarHeight: CGFloat = 0

	private init() {}
}
