//
//  roamrApp.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI
import FirebaseCore

@main
struct roamr: App {
    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
