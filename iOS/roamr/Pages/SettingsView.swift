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
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var authManager: AuthManager { AuthManager.shared }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Settings",
                statusText: authManager.isAuthenticated ? "\(authManager.email)" : "Not signed in",
                statusColor: authManager.isAuthenticated ? .green : .gray
            ) {
                ProfileButton(isAuthenticated: authManager.isAuthenticated)
            }

			VStack(spacing: 24) {
				Spacer()
				appInfoSection

				accountSection
				Spacer()
			}
			.padding(.vertical)
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.bottom, safeAreaInsets.bottom + AppConstants.shared.tabBarHeight)
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(spacing: 16) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if authManager.isAuthenticated {
                // Signed in - show sign out button
				Button {
					signOut()
				} label: {
					HStack(spacing: 10) {
						Image(systemName: "rectangle.portrait.and.arrow.right")
							.font(.body)
						Text("Sign Out")
							.fontWeight(.medium)
					}
					.padding(.horizontal, 20)
					.padding(.vertical, 14)
					.background(Color.red)
					.foregroundStyle(.white)
					.clipShape(Capsule())
					.overlay(
						Capsule()
							.stroke(Color.gray.opacity(0.5), lineWidth: 1)
					)
				}
            } else {
                // Not signed in - show Google sign in button
                    Button {
                        Task {
                            await signInWithGoogle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image("google")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                            Text(isLoading ? "Signing in..." : "Sign in with Google")
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .disabled(isLoading)
            }
        }
    }

    @ViewBuilder
    private var appInfoSection: some View {
        VStack(spacing: 16) {
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
    }

    private func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil

        do {
            try await AuthManager.shared.signInWithGoogle()
        } catch {
            errorMessage = AuthManager.shared.error ?? error.localizedDescription
        }

        isLoading = false
    }

    private func signOut() {
        do {
            try authManager.signOut()
            errorMessage = nil
        } catch {
            errorMessage = "Sign out failed"
        }
    }
}

struct ProfileButton: View {
    let isAuthenticated: Bool

    var body: some View {
        Image(systemName: isAuthenticated ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
            .font(.title)
            .foregroundStyle(isAuthenticated ? .green : .secondary)
            .frame(width: 44, height: 44)
            .background(isAuthenticated ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
            .clipShape(Circle())
    }
}
