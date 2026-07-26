import Combine
import Foundation
import Security

// MARK: - Server Configuration
//
// Stores the host address and port of the DoseLuma backend server.
// Credentials are kept in the iOS Keychain; host/port are in UserDefaults.
//
// Addressing uses raw IP addresses (IPv4 or IPv6) and a port number.
// No URL scheme or hostname is involved — the transport is a custom TCP protocol.

@MainActor
final class ServerConfiguration: ObservableObject {

    static let shared = ServerConfiguration()

    // MARK: IP Mode

    enum IPMode: String, CaseIterable, Identifiable {
        case auto = "Auto"   // race both — first to respond wins
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        var id: String { rawValue }
    }

    // MARK: Published state

    @Published var host:       String = ""   // primary IPv4/hostname (.local or LAN IP)
    @Published var host6:      String = ""   // optional IPv6
    @Published var serverName: String = ""   // display name for the server
    @Published var port:       Int    = 8080
    @Published var activeHost: String = ""   // winner from last connection race
    @Published var ipMode:     IPMode = .auto
    @Published var username:   String = ""
    @Published var isConfigured: Bool  = false
    @Published var connectionStatus: ConnectionStatus = .notConfigured

    enum ConnectionStatus: Equatable {
        case notConfigured
        case checking
        case connected(version: String)
        case unreachable(reason: String)
        case authFailed
    }

    // MARK: Persistence keys

    private let hostKey       = "doseluma.server.host"
    private let host6Key      = "doseluma.server.host6"
    private let serverNameKey = "doseluma.server.name"
    private let portKey       = "doseluma.server.port"
    private let ipModeKey     = "doseluma.server.ipmode"
    private let usernameKey   = "doseluma.server.username"

    /// The host that matches the current IP mode (Auto → primary).
    var selectedHost: String {
        switch ipMode {
        case .auto: return host.isEmpty ? host6 : host
        case .ipv4: return host
        case .ipv6: return host6
        }
    }

    private let keychainService = "com.doseluma.app"

    // MARK: Fixed server address
    //
    // DoseLuma talks to one backend, at a fixed address — there is no
    // discovery, and the app intentionally has no UI for entering or
    // changing a server address. Update these constants to repoint it.
    static let fixedHost = "127.0.0.1"
    static let fixedPort = 8801

    // MARK: Init

    private init() { load() }

    // MARK: Load / Save

    func load() {
        host         = Self.fixedHost
        host6        = ""
        serverName   = ""
        port         = Self.fixedPort
        username     = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        ipMode       = .ipv4
        activeHost   = selectedHost
        isConfigured = true
        connectionStatus = .unreachable(reason: "Not yet checked")
    }

    func save(host: String, host6: String = "", port: Int = 8080, username: String, password: String) {
        // Strip interface scope IDs (e.g. "10.0.0.1%en0" → "10.0.0.1", "fe80::1%en0" → "fe80::1")
        let stripZone: (String) -> String = { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pct = t.firstIndex(of: "%") { return String(t[..<pct]) }
            return t
        }
        let trimHost  = stripZone(host)
        let trimHost6 = stripZone(host6)
        let safePort  = port > 0 ? port : 8080
        UserDefaults.standard.set(trimHost,            forKey: hostKey)
        UserDefaults.standard.set(trimHost6,           forKey: host6Key)
        UserDefaults.standard.set(safePort,            forKey: portKey)
        UserDefaults.standard.set(ipMode.rawValue,     forKey: ipModeKey)
        UserDefaults.standard.set(username,            forKey: usernameKey)
        if !password.isEmpty { savePassword(password, account: keychainAccount) }
        self.host     = trimHost
        self.host6    = trimHost6
        self.port     = safePort
        self.username = username
        isConfigured  = !trimHost.isEmpty
        activeHost    = selectedHost
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: hostKey)
        UserDefaults.standard.removeObject(forKey: host6Key)
        UserDefaults.standard.removeObject(forKey: serverNameKey)
        UserDefaults.standard.removeObject(forKey: portKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
        deletePassword(account: keychainAccount)
        host         = ""
        host6        = ""
        serverName   = ""
        port         = 8080
        activeHost   = ""
        ipMode       = .auto
        username     = ""
        isConfigured = false
        connectionStatus = .notConfigured
    }

    // MARK: Credential helpers (Keychain)

    private let defaultKeychainAccount = "api-key"
    private let openAIKeychainAccount = "openai-api-key"

    private var keychainAccount: String {
        username.isEmpty ? defaultKeychainAccount : username
    }

    // MARK: OpenAI API Key

    /// OpenAI API key for LLM-powered OCR cleanup. Stored securely in Keychain.
    var openAIAPIKey: String {
        readPassword(account: openAIKeychainAccount) ?? ""
    }

    var isOpenAIConfigured: Bool {
        !openAIAPIKey.isEmpty
    }

    func saveOpenAIAPIKey(_ key: String) {
        if key.isEmpty {
            deletePassword(account: openAIKeychainAccount)
        } else {
            savePassword(key, account: openAIKeychainAccount)
        }
    }

    func clearOpenAIAPIKey() {
        deletePassword(account: openAIKeychainAccount)
    }

    func loadPassword() -> String? {
        readPassword(account: keychainAccount)
    }

    private func savePassword(_ password: String, account: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private func readPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deletePassword(account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
