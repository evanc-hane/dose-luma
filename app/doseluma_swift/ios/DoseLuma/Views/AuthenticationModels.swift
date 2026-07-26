import Foundation

// MARK: - Authentication API Models
//
// Request/Response structures for the authentication endpoints

// MARK: - Login

// AuthResponse is returned by /api/auth/register
struct AuthResponse: Decodable {
    let userID: String
    let displayName: String
    let role: String
    let phone: String?
    let token: String
    let apiKey: String?
    
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case role
        case phone
        case token
        case apiKey = "api_key"
    }
}

// MARK: - Registration

struct RegisterRequest: Encodable {
    let username: String
    let displayName: String
    let phone: String
    let password: String
    let role: String
    
    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case phone
        case password
        case role
    }
}
// MARK: - Empty Response

struct EmptyResponse: Decodable {
    // Used for endpoints that return no data
}

// MARK: - Auth Refresh Response
// Returned by /api/auth/refresh

struct AuthRefreshResponse: Decodable {
    let userID: String
    let displayName: String
    let role: String
    let phone: String?
    let token: String
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case role
        case phone
        case token
        case apiKey = "api_key"
    }
}

