//
//  roamrApp.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct roamr: App {
    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
