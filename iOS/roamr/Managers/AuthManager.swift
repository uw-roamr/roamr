//
//  AuthManager.swift
//  roamr
//
//  Firebase Auth wrapper with @Observable pattern
//

import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseCore
import GoogleSignIn

@Observable
class AuthManager {
    static let shared = AuthManager()

    private(set) var currentUser: User?
    private(set) var isLoading = false
    private(set) var error: String?

    var isAuthenticated: Bool {
        currentUser != nil
    }

    var displayName: String {
        currentUser?.displayName ?? "User"
    }

    var email: String {
        currentUser?.email ?? ""
    }

    private var authStateListener: AuthStateDidChangeListenerHandle?

    private init() {
        setupAuthStateListener()
    }

    private func setupAuthStateListener() {
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.currentUser = user
        }
    }

    @MainActor
    func signInWithGoogle() async throws {
        isLoading = true
        error = nil

        guard let clientID = FirebaseApp.app()?.options.clientID else {
            isLoading = false
            self.error = "Firebase configuration error"
            throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing client ID"])
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            isLoading = false
            self.error = "Unable to get root view controller"
            throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No root view controller"])
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            guard let idToken = result.user.idToken?.tokenString else {
                isLoading = false
                self.error = "Failed to get ID token"
                throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing ID token"])
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )

            let authResult = try await Auth.auth().signIn(with: credential)

            // Create user document if it doesn't exist
            let db = Firestore.firestore()
            let userDoc = try await db.collection("users").document(authResult.user.uid).getDocument()
            if !userDoc.exists {
                try await db.collection("users").document(authResult.user.uid).setData([
                    "email": authResult.user.email ?? "",
                    "displayName": authResult.user.displayName ?? "",
                    "createdAt": FieldValue.serverTimestamp(),
                    "uploadCount": 0
                ])
            }

            isLoading = false
        } catch {
            isLoading = false
            self.error = error.localizedDescription
            throw error
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws {
        isLoading = true
        error = nil

        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let changeRequest = result.user.createProfileChangeRequest()
            changeRequest.displayName = displayName
            try await changeRequest.commitChanges()

            let db = Firestore.firestore()
            try await db.collection("users").document(result.user.uid).setData([
                "email": email,
                "displayName": displayName,
                "createdAt": FieldValue.serverTimestamp(),
                "uploadCount": 0
            ])

            isLoading = false
        } catch {
            isLoading = false
            self.error = getErrorMessage(for: error)
            throw error
        }
    }

    func signIn(email: String, password: String) async throws {
        isLoading = true
        error = nil

        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
            isLoading = false
        } catch {
            isLoading = false
            self.error = getErrorMessage(for: error)
            throw error
        }
    }

    func signOut() throws {
        do {
            try Auth.auth().signOut()
            error = nil
        } catch {
            self.error = getErrorMessage(for: error)
            throw error
        }
    }

    private func getErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain else {
            return error.localizedDescription
        }

        switch AuthErrorCode(rawValue: nsError.code) {
        case .emailAlreadyInUse:
            return "This email is already registered."
        case .invalidEmail:
            return "Invalid email address."
        case .weakPassword:
            return "Password should be at least 6 characters."
        case .userNotFound, .wrongPassword, .invalidCredential:
            return "Invalid email or password."
        case .tooManyRequests:
            return "Too many attempts. Please try again later."
        default:
            return "An error occurred. Please try again."
        }
    }
}
