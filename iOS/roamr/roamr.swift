//
//  roamrApp.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI

@main
struct roamr: App {
	@StateObject private var lidarManager = LiDARManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
				.environmentObject(lidarManager)
        }
    }
}
