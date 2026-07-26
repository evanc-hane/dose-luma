import Combine
import SwiftUI
import LiveKit

// MARK: - VoiceView
//
// Same LiveKit connect flow as DoseLuma Server / talk.html / the DoseLuma mobile
// apps — POST /api/livekit/connect, join the room, publish the mic.
// Fixed backend address (ServerConfiguration.fixedHost/fixedPort) — no URL
// entry. One big button: press to talk, press again to end the call.

@MainActor
final class VoiceSessionModel: ObservableObject {
    // Shared, not per-view — a scheduled check-in needs to be able to start
    // a call (see BackendClient's "checkin_ready" handling) regardless of
    // whether VoiceView currently happens to be on screen.
    static let shared = VoiceSessionModel()

    enum Status: Equatable { case idle, connecting, connected, error(String) }

    @Published var status: Status = .idle
    @Published var micEnabled = false
    @Published private(set) var room: Room?
    @Published var micLevel: Float = 0

    private var levelTimer: Timer?

    private var backendURL: String {
        "http://\(ServerConfiguration.fixedHost):\(ServerConfiguration.fixedPort)"
    }

    func start() {
        // Also guards against a scheduled check-in re-triggering start() while
        // a call (user- or check-in-initiated) is already in progress.
        guard status != .connecting && status != .connected else { return }
        status = .connecting
        Task {
            do {
                // Stable per-user identity (not a per-call timestamp) — the
                // backend's session cache and dispatch cooldown are keyed on
                // this, and LiveKit needs it to recognize a reconnect as the
                // same participant rejoining the same room, not a stranger
                // triggering a fresh dispatch every call.
                let identity = "doseluma-\(UserSession.shared.currentUser?.id ?? "guest")"
                let displayName = UserSession.shared.currentUser?.displayName ?? "doseluma"
                let data = try await VoiceAgentClient.connect(
                    backendURL: backendURL, userIdentity: identity, userName: displayName
                )
                let newRoom = Room()
                try await newRoom.connect(url: data.url, token: data.token)
                try await newRoom.localParticipant.setMicrophone(enabled: true)

                self.room = newRoom
                self.micEnabled = true
                self.status = .connected
                self.startLevelTimer()
            } catch {
                self.status = .error(error.localizedDescription)
            }
        }
    }

    func stop() {
        levelTimer?.invalidate()
        levelTimer = nil
        micLevel = 0
        let current = room
        room = nil
        micEnabled = false
        status = .idle
        Task { await current?.disconnect() }
    }

    func toggleTalk() {
        switch status {
        case .idle, .error:
            start()
        case .connecting, .connected:
            stop()
        }
    }

    func toggleMute() {
        guard let room else { return }
        let next = !micEnabled
        Task {
            try? await room.localParticipant.setMicrophone(enabled: next)
            self.micEnabled = next
        }
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let room = self.room else { return }
            Task { @MainActor in
                self.micLevel = room.localParticipant.audioLevel
            }
        }
    }
}

struct VoiceView: View {
    @ObservedObject private var session = VoiceSessionModel.shared

    private var statusText: String {
        switch session.status {
        case .idle: return "Tap to talk to ALI"
        case .connecting: return "Connecting…"
        case .connected: return "Listening…"
        case .error: return "Couldn’t connect — tap to retry"
        }
    }

    private var circleColor: Color {
        switch session.status {
        case .idle: return .blue
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Text("Talk to ALI")
                    .font(.title2.bold())
                Text("Your voice check-in companion")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                ZStack {
                    // Mic-level pulse ring, visible only while connected
                    Circle()
                        .stroke(circleColor.opacity(0.35), lineWidth: 6)
                        .frame(width: 190 + CGFloat(session.micLevel) * 60,
                               height: 190 + CGFloat(session.micLevel) * 60)
                        .opacity(session.status == .connected ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: session.micLevel)

                    if session.status == .connecting {
                        Circle()
                            .stroke(circleColor.opacity(0.5), lineWidth: 4)
                            .frame(width: 190, height: 190)
                            .scaleEffect(1.15)
                            .opacity(0.6)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: session.status)
                    }

                    Button(action: { session.toggleTalk() }) {
                        Circle()
                            .fill(circleColor.gradient)
                            .frame(width: 160, height: 160)
                            .overlay {
                                Image(systemName: iconName)
                                    .font(.system(size: 56, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .shadow(color: circleColor.opacity(0.4), radius: 16, y: 6)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)

                Text(statusText)
                    .font(.subheadline.bold())
                    .foregroundStyle(circleColor)

                if case let .error(message) = session.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                if session.status == .connected {
                    Button(session.micEnabled ? "Mute" : "Unmute") { session.toggleMute() }
                        .buttonStyle(.bordered)
                }

                Spacer()
                Spacer()
            }
            .padding(20)
            #if os(iOS)
            .navigationTitle("Voice")
            #endif
            .onDisappear { session.stop() }
        }
    }

    private var iconName: String {
        switch session.status {
        case .idle, .error: return "mic.fill"
        case .connecting: return "ellipsis"
        case .connected: return "waveform"
        }
    }
}
