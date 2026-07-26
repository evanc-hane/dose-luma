import Combine
import Foundation

// MARK: - API Errors

enum APIError: LocalizedError {
    case notConfigured
    case httpError(statusCode: Int, body: String)
    case networkError(underlying: Error)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No server configured."
        case .httpError(let code, let body):
            if !body.isEmpty {
                return "Server returned status \(code): \(body)"
            }
            return "Server returned status \(code)."
        case .networkError(let e):
            return "Network error: \(e.localizedDescription)"
        case .decodingError(let e):
            return "Could not parse server response: \(e.localizedDescription)"
        }
    }
}

struct HealthResponse: Decodable {
    let status: String
    let version: String?
}

// MARK: - APIClient
//
// Plain HTTP client for the fixed DoseLuma backend (app/backend) — a stock
// FastAPI app, so this just does normal URLSession requests. (An earlier
// version of this client spoke a custom WebSocket-RPC protocol matching a
// different, now-deleted backend; that protocol has no server anywhere in
// this repo, so it always failed. Removed.)

@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()
    private init() {}

    private var baseURL: String {
        let config = ServerConfiguration.shared
        return "http://\(config.host):\(config.port)"
    }

    // MARK: - Connection check (used by onboarding + settings)

    func checkConnection() async {
        let config = ServerConfiguration.shared
        config.connectionStatus = .checking

        guard let url = URL(string: "\(baseURL)/api/health") else {
            config.connectionStatus = .unreachable(reason: "Invalid server address")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                config.connectionStatus = .unreachable(reason: "Server returned an error")
                return
            }
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            config.activeHost = config.host
            config.connectionStatus = .connected(version: health.version ?? health.status)
            print("[APIClient] Connected to \(config.host):\(config.port), status=\(health.status)")
        } catch {
            print("[APIClient] health check failed: \(error.localizedDescription)")
            config.connectionStatus = .unreachable(reason: error.localizedDescription)
        }
    }

    // MARK: - Public API

    func get<T: Decodable>(_ path: String, queryParams: [String: String] = [:]) async throws -> T {
        try await performRequest(method: "GET", path: path, queryParams: queryParams, extraHeaders: [:], body: nil)
    }

    func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await performRequest(method: "POST", path: path, queryParams: [:], extraHeaders: [:], body: data)
    }

    func getWithUserToken<T: Decodable>(_ path: String) async throws -> T {
        guard let token = UserSession.shared.token else { throw APIError.notConfigured }
        return try await performRequestWithRetry(
            method: "GET", path: path, queryParams: [:],
            extraHeaders: ["x-user-token": token], body: nil
        )
    }

    func postWithUserToken<B: Encodable, T: Decodable>(_ path: String, body: B, userToken: String) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await performRequestWithRetry(
            method: "POST", path: path, queryParams: [:],
            extraHeaders: ["x-user-token": userToken], body: data
        )
    }

    // MARK: - Automatic JWT refresh on 401
    //
    // If the server returns 401, attempts to refresh the JWT via
    // POST /api/auth/refresh, then retries the original request once.

    private func performRequestWithRetry<T: Decodable>(
        method: String, path: String, queryParams: [String: String],
        extraHeaders: [String: String], body: Data?
    ) async throws -> T {
        do {
            return try await performRequest(method: method, path: path,
                                            queryParams: queryParams,
                                            extraHeaders: extraHeaders, body: body)
        } catch APIError.httpError(let statusCode, let errorBody) where statusCode == 401 {
            print("[APIClient] Got 401 on \(method) \(path), attempting JWT refresh...")
            let refreshed = await UserSession.shared.refreshJWT()
            print("[APIClient] JWT refresh result: \(refreshed)")
            guard refreshed else {
                print("[APIClient] Refresh failed, propagating 401")
                throw APIError.httpError(statusCode: 401, body: errorBody)
            }

            guard let newToken = UserSession.shared.token else {
                print("[APIClient] No token after refresh, throwing notConfigured")
                throw APIError.notConfigured
            }
            print("[APIClient] Retrying \(method) \(path) with new token")
            var retryHeaders = extraHeaders
            retryHeaders["x-user-token"] = newToken
            return try await performRequest(method: method, path: path,
                                            queryParams: queryParams,
                                            extraHeaders: retryHeaders, body: body)
        }
    }

    // MARK: - Private request/response

    private func performRequest<T: Decodable>(method: String, path: String,
                                               queryParams: [String: String],
                                               extraHeaders: [String: String],
                                               body: Data?) async throws -> T {
        let config = ServerConfiguration.shared
        guard config.isConfigured else { throw APIError.notConfigured }

        var components = URLComponents(string: "\(baseURL)\(path)")
        if !queryParams.isEmpty {
            components?.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw APIError.networkError(underlying: URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let key = config.loadPassword(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(underlying: URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, body: bodyStr)
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(underlying: error)
        }
    }
}
