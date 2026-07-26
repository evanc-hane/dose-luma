import Combine
import Foundation
import WatchConnectivity

// MARK: - Watch-side session manager

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {

    static let shared = WatchSessionManager()

    @Published var medications:  [WCMedication] = []
    @Published var isReachable = false

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    // MARK: Request schedule from iPhone

    func requestSchedule() {
        guard WCSession.default.activationState == .activated else { return }
        let msg: [String: Any] = [WCMessageKey.type: WCMessageKey.requestSchedule]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Send adherence action to iPhone

    func markTaken(medication: WCMedication) {
        send(type: WCMessageKey.markTaken, medication: medication)
        removeLocal(medication)
    }

    func markSkipped(medication: WCMedication) {
        send(type: WCMessageKey.markSkipped, medication: medication)
        removeLocal(medication)
    }

    private func send(type: String, medication: WCMedication) {
        guard WCSession.default.activationState == .activated else { return }
        let payload: [String: Any] = [
            WCMessageKey.type:         type,
            WCMessageKey.medicationId: medication.id,
            WCMessageKey.windowRaw:    medication.windowRaw,
            WCMessageKey.dateEpoch:    Date().timeIntervalSince1970
        ]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            WCSession.default.transferUserInfo(payload)
        }
    }

    private func removeLocal(_ med: WCMedication) {
        medications.removeAll { $0.id == med.id && $0.windowRaw == med.windowRaw }
    }
}

// MARK: - WCSessionDelegate (Watch)

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if activationState == .activated {
                // Check if we have a persisted context from a background transfer
                self.applySchedule(from: session.receivedApplicationContext)
                self.requestSchedule()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable { self.requestSchedule() }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.applySchedule(from: message) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.applySchedule(from: userInfo) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.applySchedule(from: context) }
    }

    private func applySchedule(from message: [String: Any]) {
        guard let type = message[WCMessageKey.type] as? String,
              type == WCMessageKey.schedule,
              let data = message[WCMessageKey.schedule] as? Data,
              let meds = try? JSONDecoder().decode([WCMedication].self, from: data)
        else { return }
        medications = meds
    }
}

// MARK: - Shared message keys (duplicated here — no shared framework in this project)

enum WCMessageKey {
    static let type            = "type"
    static let schedule        = "schedule"
    static let pending         = "pending"
    static let markTaken       = "markTaken"
    static let markSkipped     = "markSkipped"
    static let medicationId    = "medicationId"
    static let windowRaw       = "window"
    static let dateEpoch       = "date"
    static let requestSchedule = "requestSchedule"
}

struct WCMedication: Codable, Identifiable {
    let id:        String
    let name:      String
    let dosage:    String
    let windowRaw: String
    let isPending: Bool
}
