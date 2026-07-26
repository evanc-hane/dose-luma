import Foundation

// MARK: - VoiceAgentClient
//
// Mints a LiveKit room token from the FastAPI backend and dispatches the
// voice agent — same /api/livekit/connect endpoint and request/response
// shape the DoseLuma mobile apps and talk.html use (see
// app/backend/index.py: LiveKitConnectRequest / LiveKitConnectResponse).

struct LiveKitConnectResponse: Decodable {
    let url: String
    let token: String
    let room: String
    let user: String
    let agentName: String
    let agentDispatched: Bool

    enum CodingKeys: String, CodingKey {
        case url, token, room, user
        case agentName = "agent_name"
        case agentDispatched = "agent_dispatched"
    }
}

enum VoiceAgentClient {
    static func connect(backendURL: String, userIdentity: String, userName: String) async throws -> LiveKitConnectResponse {
        let base = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/livekit/connect") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "room_name": "",
            "user_identity": userIdentity,
            "user_name": userName,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(LiveKitConnectResponse.self, from: data)
    }
}
