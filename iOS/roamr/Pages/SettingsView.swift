//
//  SettingsPage.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import Foundation
import SwiftUI

struct SettingsPage: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @State private var showLoginSheet = false

    private var authManager: AuthManager { AuthManager.shared }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                accountSection

                Divider()
                    .padding(.horizontal)

                appInfoSection
            }
            .padding(.vertical)
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(spacing: 16) {
            Text("Account")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            if authManager.isAuthenticated {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(authManager.displayName)
                                .font(.headline)
                            Text(authManager.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    Button {
                        signOut()
                    } label: {
                        Text("Sign Out")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Sign in to access your WASM files and sync across devices")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button {
                        showLoginSheet = true
                    } label: {
                        Text("Sign In")
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private var appInfoSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("roamr")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Really Open-Source Autonomous Robot")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
        }
        .padding(.top, 20)
    }

    private func signOut() {
        do {
            try authManager.signOut()
        } catch {
            print("Sign out error: \(error)")
        }
    }
}
