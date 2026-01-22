//
//  LoginView.swift
//  roamr
//
//  Sign in sheet presented from Settings
//

import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)

                    Text("Welcome")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Sign in to access your WASM files")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task {
                        await signInWithGoogle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "g.circle.fill")
                            .font(.title2)
                        Text(isLoading ? "Signing in..." : "Continue with Google")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(.horizontal)
                .disabled(isLoading)

                Spacer()
                Spacer()
            }
            .padding(.bottom, 40)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil

        do {
            try await AuthManager.shared.signInWithGoogle()
            dismiss()
        } catch {
            errorMessage = AuthManager.shared.error ?? error.localizedDescription
        }

        isLoading = false
    }
}
