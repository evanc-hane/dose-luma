import Combine
import Foundation

// MARK: - User Role

enum UserRole: String, Codable, CaseIterable {
    case patient   = "patient"
    case caregiver = "caregiver"
    case both      = "both"

    var label: String {
        switch self {
        case .patient:   return "Patient"
        case .caregiver: return "Caregiver"
        case .both:      return "Both"
        }
    }

    var icon: String {
        switch self {
        case .patient:   return "person.fill"
        case .caregiver: return "person.2.fill"
        case .both:      return "person.2.circle.fill"
        }
    }

    var description: String {
        switch self {
        case .patient:   return "I take medications and want to track my adherence"
        case .caregiver: return "I monitor someone else's medication adherence"
        case .both:      return "I take medications and also care for others"
        }
    }

    var showsPatientTabs: Bool { self == .patient || self == .both }
    var showsCaregiverTab: Bool { self == .caregiver || self == .both }
}

// MARK: - User Profile

struct UserProfile: Codable {
    let id: String
    let username: String
    let displayName: String
    let phone: String
    let role: UserRole
}

// MARK: - UserSession
// Manages authentication state, onboarding, and current user identity.

@MainActor
final class UserSession: NSObject, ObservableObject {

    static let shared = UserSession()
    private override init() {
        super.init()
        debugPrint("[UserSession] Initializing UserSession singleton")
        load()
        // Re-publish ServerConfiguration changes to ensure hasCompletedOnboarding is reactive
        ServerConfiguration.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in 
                debugPrint("[UserSession] ServerConfiguration changed")
                self?.objectWillChange.send() 
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    @Published var currentUser: UserProfile? {
        didSet {
            if currentUser == nil {
                debugPrint("[UserSession] ⚠️ currentUser set to nil!")
                debugPrint("[UserSession] Stack trace: \(Thread.callStackSymbols.joined(separator: "\n"))")
            } else if let user = currentUser {
                debugPrint("[UserSession] currentUser set to: \(user.username)")
            }
        }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?

    var isLoggedIn: Bool { 
        let loggedIn = currentUser != nil
        if !loggedIn {
            debugPrint("[UserSession] isLoggedIn check: FALSE - no currentUser")
        }
        return loggedIn
    }

    /// True once the user has completed the full onboarding flow
    /// (server connect → role → profile creation).
    var hasCompletedOnboarding: Bool {
        // If we have a logged-in user, consider onboarding complete
        // The user can fix server connection issues from Settings
        let completed = isLoggedIn
        debugPrint("[UserSession] hasCompletedOnboarding check: \(completed), currentUser: \(currentUser?.username ?? "nil")")
        return completed
    }

    private let tokenKey       = "doseluma.userToken"
    private let profileKey     = "doseluma.userProfile"
    private let refreshTokenKey = "doseluma.refreshToken"

    /// Refresh the backend JWT via the server's generic refresh endpoint.
    func refreshJWT() async -> Bool {
        guard let token = self.token, !token.isEmpty else {
            debugPrint("[UserSession] refreshJWT: no token stored")
            return false
        }
        debugPrint("[UserSession] refreshJWT: attempting refresh...")
        do {
            let resp: AuthRefreshResponse = try await APIClient.shared.post(
                "/api/auth/refresh",
                body: ["token": token]
            )
            debugPrint("[UserSession] refreshJWT: success, user_id=\(resp.userID)")
            persist(UserProfile(id: resp.userID, username: resp.displayName,
                               displayName: resp.displayName, phone: resp.phone ?? "",
                               role: UserRole(rawValue: resp.role) ?? .patient),
                   token: resp.token)
            return true
        } catch {
            debugPrint("[UserSession] refreshJWT failed: \(error)")
            // Clear the dead session so the app shows the login screen
            logout()
            debugPrint("[UserSession] refreshJWT: session cleared via logout()")
            return false
        }
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            currentUser = profile
            debugPrint("[UserSession] Loaded user: \(profile.username)")
            // The cached profile can go stale (e.g. a name edited directly in
            // users.json on the backend) since nothing else proactively
            // re-syncs it. Refresh from the server on launch so it self-heals.
            Task { await self.refreshJWT() }
        } else {
            debugPrint("[UserSession] No saved user found")
        }
    }

    func persist(_ profile: UserProfile, token: String) {
        debugPrint("[UserSession] Persisting user: \(profile.username)")
        currentUser = profile
        UserDefaults.standard.set(token, forKey: tokenKey)
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
            UserDefaults.standard.synchronize() // Force immediate save
            debugPrint("[UserSession] User data saved to UserDefaults")
        } else {
            debugPrint("[UserSession] ERROR: Failed to encode user profile")
        }
    }

    /// Update the phone number locally and sync to server.
    func updatePhoneNumber(_ phone: String) {
        guard var profile = currentUser else { return }
        profile = UserProfile(
            id: profile.id,
            username: profile.username,
            displayName: profile.displayName,
            phone: phone,
            role: profile.role
        )
        persist(profile, token: UserDefaults.standard.string(forKey: tokenKey) ?? "")

        // Sync to server asynchronously
        Task {
            do {
                let _: EmptyResponse = try await APIClient.shared.postWithUserToken(
                    "/api/user/profile",
                    body: ["phone": phone] as [String: String],
                    userToken: UserDefaults.standard.string(forKey: tokenKey) ?? ""
                )
                debugPrint("[UserSession] Phone number synced to server")
            } catch {
                debugPrint("[UserSession] Failed to sync phone to server: \(error)")
            }
        }
    }

    var token: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    // MARK: Auth

    func register(username: String, displayName: String, phone: String, password: String, role: UserRole) async {
        debugPrint("[UserSession] Register attempt - username: \(username), displayName: \(displayName)")
        isLoading = true
        errorMessage = nil
        do {
            debugPrint("[UserSession] Sending registration request to server...")
            let resp: AuthResponse = try await APIClient.shared.post(
                "/api/auth/register",
                body: RegisterRequest(username: username, displayName: displayName,
                                     phone: phone, password: password, role: role.rawValue)
            )
            debugPrint("[UserSession] Registration response received - userID: \(resp.userID)")
            let profileRole = UserRole(rawValue: resp.role) ?? role
            persist(UserProfile(id: resp.userID, username: username,
                               displayName: resp.displayName, phone: phone, role: profileRole),
                   token: resp.token)
            debugPrint("[UserSession] Registration successful, user persisted")
            // Store the API key returned by the server so future requests are authenticated
            if let key = resp.apiKey, !key.isEmpty {
                debugPrint("[UserSession] Saving API key to ServerConfiguration")
                let cfg = ServerConfiguration.shared
                cfg.save(host: cfg.host, host6: cfg.host6, port: cfg.port,
                         username: username, password: key)
                debugPrint("[UserSession] API key saved")
            }
        } catch {
            debugPrint("[UserSession] Registration failed: \(error)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
        debugPrint("[UserSession] Registration process complete. isLoggedIn: \(isLoggedIn), currentUser: \(currentUser?.username ?? "nil")")
    }

    func logout() {
        debugPrint("[UserSession] ⚠️ LOGOUT called!")
        debugPrint("[UserSession] Stack trace: \(Thread.callStackSymbols.joined(separator: "\n"))")
        currentUser = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        debugPrint("[UserSession] Logout complete")
    }

    func registerPushToken(_ deviceToken: String) {
        guard let user = currentUser, let token = self.token else { return }
        let deviceID = UserDefaults.standard.string(forKey: "doseluma.device_id") ?? ""
        let payload = PushTokenRequest(userID: user.id, deviceToken: deviceToken, deviceID: deviceID)
        Task {
            do {
                let _: EmptyResponse = try await APIClient.shared.postWithUserToken(
                    "/api/users/push-token", body: payload, userToken: token
                )
            } catch {
                debugPrint("[UserSession] push token registration failed: \(error)")
            }
        }
    }
}

// MARK: - API Request/Response types
// Note: Authentication models (RegisterRequest, AuthResponse, EmptyResponse) 
// are now defined in AuthenticationModels.swift

struct PushTokenRequest: Encodable {
    let userID: String
    let deviceToken: String
    let deviceID: String
    enum CodingKeys: String, CodingKey {
        case userID      = "user_id"
        case deviceToken = "device_token"
        case deviceID    = "device_id"
    }
}

