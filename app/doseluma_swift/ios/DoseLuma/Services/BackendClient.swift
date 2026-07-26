import Foundation
import Combine

// MARK: - BackendClient
//
// Talks to the FastAPI backend (app/backend) — same contract the
// DoseLuma caregiver dashboard and DoseLuma Server use. Adherence/alert
// state (and check-in activation — see below) is pushed over a persistent
// WebSocket at /ws/state (see app/backend/state_bus.py) instead of being
// polled: the backend sends a fresh snapshot on connect, then a new message
// every time a dose is marked taken, an intent is classified, an alert is
// dismissed, or a scheduled medication check-in fires (scheduler.py) — by
// this client, another connected client, or the proactive scheduler.
//
// Kept connected app-wide (not just while CaregiverView is visible) so a
// scheduled check-in can reach the patient even if they're on another tab —
// see the "checkin_ready" handling below and MainTabView's listener.

struct RemoteAdherenceRecord: Decodable, Identifiable {
    let id: String
    let name: String
    let time: String
    let status: String   // "taken" | "missed" | "pending"
    let takenAt: String?
    // Only present on alert entries (not plain medication-status entries).
    let type: String?
    let priority: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case id, name, time, status, type, priority, message
        case takenAt = "taken_at"
    }
}

struct CheckInEvent: Equatable {
    let room: String
    let medicationName: String
}

private struct StateMessage: Decodable {
    let type: String
    let medications: [RemoteAdherenceRecord]?
    let alerts: [RemoteAdherenceRecord]?
    let room: String?
    let medicationName: String?

    enum CodingKeys: String, CodingKey {
        case type, medications, alerts, room
        case medicationName = "medication_name"
    }
}

@MainActor
final class BackendClient: ObservableObject {
    static let shared = BackendClient()

    private static let reconnectDelayNanos: UInt64 = 3_000_000_000

    @Published var backendOK: Bool?
    @Published var alerts: [RemoteAdherenceRecord] = []
    @Published var medications: [RemoteAdherenceRecord] = []
    @Published var errorMessage: String?
    /// Set when the scheduler fires a check-in; MainTabView observes this to
    /// jump to the Voice tab and start the call, then clears it.
    @Published var pendingCheckIn: CheckInEvent?

    private var socket: URLSessionWebSocketTask?
    private var listenTask: Task<Void, Never>?
    /// Alert ids already seen — used to detect newly-arrived alerts so the
    /// caregiver "ding" only fires for genuinely new ones, not every alert
    /// still open from before this connection/launch.
    private var knownAlertIDs: Set<String>?

    private init() {}

    // DoseLuma talks to one fixed backend — same address as everywhere else
    // in the app (ServerConfiguration.fixedHost/fixedPort). No separate URL
    // to configure or drift out of sync with.
    private var base: String {
        "http://\(ServerConfiguration.fixedHost):\(ServerConfiguration.fixedPort)"
    }

    private var stateSocketURL: URL? {
        let wsBase = base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return URL(string: "\(wsBase)/ws/state")
    }

    // MARK: - WebSocket lifecycle

    /// Opens (or re-opens) the /ws/state connection. Safe to call repeatedly —
    /// e.g. on app foreground, after editing backendURL, or as a manual retry.
    func connect() {
        disconnect()
        guard let url = stateSocketURL else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        listen(on: task)
    }

    func disconnect() {
        listenTask?.cancel()
        listenTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func listen(on task: URLSessionWebSocketTask) {
        listenTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self.backendOK = true
                    self.errorMessage = nil
                    self.apply(message)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.backendOK = false
                    self.errorMessage = error.localizedDescription
                    try? await Task.sleep(nanoseconds: Self.reconnectDelayNanos)
                    guard !Task.isCancelled else { return }
                    self.connect()
                    return
                }
            }
        }
    }

    private func apply(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StateMessage.self, from: data) else { return }
        if let medications = decoded.medications { self.medications = medications }
        if let alerts = decoded.alerts {
            self.alerts = alerts
            dingForNewAlerts(alerts, isInitialSnapshot: decoded.type == "snapshot")
        }
        if decoded.type == "checkin_ready", let room = decoded.room {
            pendingCheckIn = CheckInEvent(room: room, medicationName: decoded.medicationName ?? "")
        }
    }

    /// Caregiver-side "ding": fires a local notification (banner + sound,
    /// even in foreground — see NotificationManager's delegate) for every
    /// alert id that wasn't already known. The very first snapshot after
    /// connecting only seeds `knownAlertIDs` — it doesn't ding for alerts
    /// that were already open before this launch/reconnect.
    private func dingForNewAlerts(_ alerts: [RemoteAdherenceRecord], isInitialSnapshot: Bool) {
        let role = UserSession.shared.currentUser?.role
        guard role == .caregiver || role == .both else { return }

        let currentIDs = Set(alerts.map(\.id))
        defer { knownAlertIDs = currentIDs }

        guard let known = knownAlertIDs, !isInitialSnapshot else { return }
        for alert in alerts where !known.contains(alert.id) {
            NotificationManager.shared.notifyCaregiverAlert(
                title: alertTitle(for: alert.type),
                body: alert.message?.isEmpty == false ? alert.message! : "\(alert.name) — \(alert.status)"
            )
        }
    }

    private func alertTitle(for type: String?) -> String {
        switch type {
        case "distress": return "Distress alert"
        case "confused": return "Confusion alert"
        case "refused": return "Medication refused"
        case "overdose_risk": return "Possible double dose"
        case "missed": return "Missed dose"
        default: return "Caregiver alert"
        }
    }

    // MARK: - Actions

    func dismissAlert(_ id: String) async {
        do {
            try await post("/api/alerts/\(id)/dismiss")
            // The backend also broadcasts the update over /ws/state; this
            // just avoids a visible delay before that round-trip lands.
            alerts.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - HTTP helpers

    private func post(_ path: String) async throws {
        guard let url = URL(string: "\(base)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response)
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
