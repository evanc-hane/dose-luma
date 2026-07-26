import Foundation
import Combine

// MARK: - Shared message keys (must match Watch side)

enum WCMessageKey {
    static let type            = "type"
    // iPhone → Watch
    static let schedule        = "schedule"     // [WCMedication] encoded
    static let pending         = "pending"      // [WCMedication] for current window
    // Watch → iPhone
    static let markTaken       = "markTaken"
    static let markSkipped     = "markSkipped"
    static let medicationId    = "medicationId"
    static let windowRaw       = "window"
    static let dateEpoch       = "date"
    // Watch → iPhone (request)
    static let requestSchedule = "requestSchedule"
}

// MARK: - Lightweight Codable model for WCSession transfer
// (avoids shipping the full MedicationStore model across the session boundary)

struct WCMedication: Codable {
    let id:          String
    let name:        String
    let dosage:      String
    let windowRaw:   String   // TimeWindow.rawValue
    let isPending:   Bool     // true if not yet logged for today
}

#if os(iOS)
import WatchConnectivity

// MARK: - iPhone-side session manager

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {

    static let shared = WatchSessionManager()

    @Published var isReachable = false

    private var store: MedicationStore?
    private var session: WCSession?

    func activate(store: MedicationStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
    }

    // MARK: Push schedule to Watch

    func pushSchedule() {
        guard let session, session.activationState == .activated,
              session.isWatchAppInstalled else { return }
        guard let store else { return }

        let today = Date()
        var meds: [WCMedication] = []

        for med in store.medications where med.isActive {
            for windowID in med.timeWindowIDs {
                guard let window = store.timeWindow(byID: windowID) else { continue }
                let pending = store.status(for: med, window: window, on: today) == nil
                meds.append(WCMedication(
                    id:        med.id.uuidString,
                    name:      med.name,
                    dosage:    med.dosage,
                    windowRaw: window.id,
                    isPending: pending
                ))
            }
        }

        guard let data = try? JSONEncoder().encode(meds) else { return }
        let payload: [String: Any] = [
            WCMessageKey.type:     WCMessageKey.schedule,
            WCMessageKey.schedule: data
        ]

        // 1. Update application context (non-transient background sync)
        try? session.updateApplicationContext(payload)

        // 2. Immediate push if reachable
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            // 3. Queue for background transfer if context update isn't enough
            session.transferUserInfo(payload)
        }
    }
}

// MARK: - WCSessionDelegate (iPhone)

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if activationState == .activated { self.pushSchedule() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable { self.pushSchedule() }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handleMessage(message) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.handleMessage(userInfo) }
    }

    // Required on iOS only
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    // MARK: Incoming message handling

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message[WCMessageKey.type] as? String else { return }

        switch type {

        case WCMessageKey.requestSchedule:
            pushSchedule()

        case WCMessageKey.markTaken:
            logAdherence(message: message, status: .taken)

        case WCMessageKey.markSkipped:
            logAdherence(message: message, status: .skipped)

        default:
            break
        }
    }

    private func logAdherence(message: [String: Any], status: AdherenceStatus) {
        guard let store,
              let idString = message[WCMessageKey.medicationId] as? String,
              let id       = UUID(uuidString: idString),
              let winRaw   = message[WCMessageKey.windowRaw] as? String,
              let window   = store.timeWindow(byID: winRaw),
              message[WCMessageKey.dateEpoch] as? Double != nil
        else { return }

        guard let med = store.medications.first(where: { $0.id == id }) else { return }

        switch status {
        case .taken:   store.logTaken(med, window: window, source: .watch)
        case .skipped: store.logSkipped(med, window: window, source: .watch)
        case .missed:  break
        }

        // Refresh Watch after logging
        pushSchedule()
    }
}

#else

// MARK: - Non-iOS stub
//
// WatchConnectivity only exists on iOS. macOS builds get a no-op stand-in
// so shared callers (MedicationStore, DoseLumaApp) don't need platform
// guards at every call site.

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()
    @Published var isReachable = false
    func activate(store: MedicationStore) {}
    func pushSchedule() {}
}

#endif
