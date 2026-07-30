import Combine
import Foundation
import UserNotifications

// MARK: - Medication Store

@MainActor
final class MedicationStore: ObservableObject {

    @Published var medications: [Medication] = [] {
        didSet {
            print("💊 Medications array changed. Old count: \(oldValue.count), New count: \(medications.count)")
            if medications.count > oldValue.count {
                print("⚠️ MEDICATIONS INCREASED - possible unexpected reload!")
            }
        }
    }
    @Published var adherenceRecords: [AdherenceRecord] = []
    @Published var timeWindows: [TimeWindow] = []

    private let medsKey      = "doseluma.medications"
    private let adherenceKey = "doseluma.adherence"
    private let windowsKey   = "doseluma.timeWindows"

    init() {
        load()
        NotificationManager.shared.requestPermission()
    }

    // MARK: Persistence

    func save() {
        if let d = try? JSONEncoder().encode(medications)      { UserDefaults.standard.set(d, forKey: medsKey) }
        if let d = try? JSONEncoder().encode(adherenceRecords) { UserDefaults.standard.set(d, forKey: adherenceKey) }
        if let d = try? JSONEncoder().encode(timeWindows)      { UserDefaults.standard.set(d, forKey: windowsKey) }
    }

    private func load() {
        print("📥 Loading medications from UserDefaults")
        if let d = UserDefaults.standard.data(forKey: medsKey),
           let v = try? JSONDecoder().decode([Medication].self, from: d) { 
            medications = v 
            print("✅ Loaded \(v.count) medications")
        }
        if let d = UserDefaults.standard.data(forKey: adherenceKey),
           let v = try? JSONDecoder().decode([AdherenceRecord].self, from: d) { adherenceRecords = v }

        if let d = UserDefaults.standard.data(forKey: windowsKey),
           let v = try? JSONDecoder().decode([TimeWindow].self, from: d) {
            timeWindows = v
        } else {
            timeWindows = TimeWindow.defaultWindows
        }
    }

    func applyAuthoritativeSnapshot(medications: [Medication], adherenceRecords: [AdherenceRecord], timeWindows: [TimeWindow]) {
        print("🔄 Applying authoritative snapshot with \(medications.count) medications")
        self.medications = medications
        self.adherenceRecords = adherenceRecords
        self.timeWindows = timeWindows.isEmpty ? TimeWindow.defaultWindows : timeWindows
        save()
        NotificationManager.shared.schedule(medications: self.medications, timeWindows: sortedTimeWindows)
        WatchSessionManager.shared.pushSchedule()
    }

    // MARK: Time Window Queries

    var sortedTimeWindows: [TimeWindow] {
        timeWindows.sorted { $0.sortOrder < $1.sortOrder }
    }

    func timeWindow(byID id: String) -> TimeWindow? {
        timeWindows.first { $0.id == id }
    }

    // MARK: Time Window CRUD

    func addTimeWindow(_ window: TimeWindow) {
        timeWindows.append(window)
        save()
        NotificationManager.shared.schedule(medications: medications, timeWindows: sortedTimeWindows)
    }

    func updateTimeWindow(_ window: TimeWindow) {
        guard let i = timeWindows.firstIndex(where: { $0.id == window.id }) else { return }
        timeWindows[i] = window
        save()
        NotificationManager.shared.schedule(medications: medications, timeWindows: sortedTimeWindows)
    }

    func deleteTimeWindow(_ window: TimeWindow) {
        for i in medications.indices {
            medications[i].timeWindowIDs.removeAll { $0 == window.id }
        }
        timeWindows.removeAll { $0.id == window.id }
        save()
        NotificationManager.shared.schedule(medications: medications, timeWindows: sortedTimeWindows)
        WatchSessionManager.shared.pushSchedule()
        SyncService.shared.syncMedications(medications)
    }

    // MARK: Medication CRUD

    func add(_ med: Medication) {
        medications.append(med)
        save()
        NotificationManager.shared.schedule(medications: medications, timeWindows: sortedTimeWindows)
        WatchSessionManager.shared.pushSchedule()
        SyncService.shared.syncMedications(medications)
    }

    func update(_ med: Medication) {
        guard let i = medications.firstIndex(where: { $0.id == med.id }) else { return }
        medications[i] = med
        save()
        NotificationManager.shared.schedule(medications: medications, timeWindows: sortedTimeWindows)
        WatchSessionManager.shared.pushSchedule()
        SyncService.shared.syncMedications(medications)
    }

    func delete(_ med: Medication) {
        print("🗑️ Deleting medication: \(med.name) (ID: \(med.id))")
        print("📊 Medications count before delete: \(medications.count)")
        
        // Mark as deleted in SyncService BEFORE removing from array
        SyncService.shared.markMedicationDeleted(med.id)
        
        medications.removeAll { $0.id == med.id }
        print("📊 Medications count after delete: \(medications.count)")
        save()
        print("💾 Save completed")
        NotificationManager.shared.schedule(medications: medications, timeWindows: sortedTimeWindows)
        WatchSessionManager.shared.pushSchedule()
        SyncService.shared.syncMedications(medications)
    }

    // MARK: Schedule Queries

    func medications(for window: TimeWindow) -> [Medication] {
        medications.filter { $0.isActive && $0.timeWindowIDs.contains(window.id) }
    }

    func status(for med: Medication, window: TimeWindow, on date: Date = Date()) -> AdherenceStatus? {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        return adherenceRecords.first {
            $0.medicationId == med.id &&
            $0.windowID == window.id &&
            cal.startOfDay(for: $0.scheduledDate) == day
        }?.status
    }

    func pendingMedications(for window: TimeWindow, on date: Date = Date()) -> [Medication] {
        medications(for: window).filter { status(for: $0, window: window, on: date) == nil }
    }

    // MARK: Adherence Logging

    func logTaken(_ med: Medication, window: TimeWindow, source: AdherenceSource = .phone) {
        removeRecord(for: med, window: window)
        let r = AdherenceRecord(
            medicationId:   med.id,
            medicationName: med.name,
            dosage:         med.dosage,
            windowID:       window.id,
            scheduledDate:  Calendar.current.startOfDay(for: Date()),
            takenAt:        Date(),
            status:         .taken
        )
        adherenceRecords.append(r)
        save()
        SyncService.shared.pushAdherence(r, source: source)
    }

    func logSkipped(_ med: Medication, window: TimeWindow, source: AdherenceSource = .phone) {
        removeRecord(for: med, window: window)
        let r = AdherenceRecord(
            medicationId:   med.id,
            medicationName: med.name,
            dosage:         med.dosage,
            windowID:       window.id,
            scheduledDate:  Calendar.current.startOfDay(for: Date()),
            takenAt:        nil,
            status:         .skipped
        )
        adherenceRecords.append(r)
        save()
        SyncService.shared.pushAdherence(r, source: source)
    }

    private func removeRecord(for med: Medication, window: TimeWindow) {
        let day = Calendar.current.startOfDay(for: Date())
        adherenceRecords.removeAll {
            $0.medicationId == med.id &&
            $0.windowID == window.id &&
            Calendar.current.startOfDay(for: $0.scheduledDate) == day
        }
    }

    // MARK: Analytics

    /// Returns the fraction of scheduled doses taken over the last `days` days.
    func adherenceRate(days: Int = 7) -> Double? {
        let start = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        )
        let relevant = adherenceRecords.filter { $0.scheduledDate >= start }
        guard !relevant.isEmpty else { return nil }
        return Double(relevant.filter { $0.status == .taken }.count) / Double(relevant.count)
    }

    func recordsForDay(_ date: Date) -> [AdherenceRecord] {
        let day = Calendar.current.startOfDay(for: date)
        return adherenceRecords
            .filter { Calendar.current.startOfDay(for: $0.scheduledDate) == day }
            .sorted {
                let s0 = timeWindow(byID: $0.windowID)?.sortOrder ?? Int.max
                let s1 = timeWindow(byID: $1.windowID)?.sortOrder ?? Int.max
                return s0 < s1
            }
    }
}

// MARK: - Notification Manager

/// Schedules local push notifications following the escalation pattern from the DoseLuma proposal:
///   • Window-open reminder
///   • Urgent reminder 1 hour before close
///   • Final alert 15 minutes before close
final class NotificationManager: NSObject, @unchecked Sendable {
    static let shared = NotificationManager()
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Immediate "ding" for the caregiver side — a new alert (missed dose,
    /// distress, refusal, ...) just streamed in over /ws/state. Fires right
    /// away (trigger: nil) rather than on the reminder schedule.
    func notifyCaregiverAlert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "caregiver-alert-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func schedule(medications: [Medication], timeWindows: [TimeWindow]) {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        for window in timeWindows {
            let meds = medications.filter { $0.isActive && $0.timeWindowIDs.contains(window.id) }
            guard !meds.isEmpty else { continue }
            let names = meds.map { $0.name }.joined(separator: ", ")

            // 1. Window opens
            add(id: "doseluma.\(window.id).open",
                title: "\(window.name) Medications",
                body: names,
                hour: window.openHour, minute: window.openMinute)

            // 2. Urgent — 1 hour before window closes
            let (urgH, urgM) = subtractMinutes(60, fromHour: window.closeHour, minute: window.closeMinute)
            add(id: "doseluma.\(window.id).urgent",
                title: "Reminder: \(window.name) medications due soon",
                body: "1 hour remaining — \(names)",
                hour: urgH, minute: urgM)

            // 3. Final alert — 15 minutes before window closes
            let (finH, finM) = subtractMinutes(15, fromHour: window.closeHour, minute: window.closeMinute)
            add(id: "doseluma.\(window.id).final",
                title: "URGENT: Window closing in 15 minutes",
                body: names,
                hour: finH, minute: finM)
        }
    }

    private func subtractMinutes(_ minutes: Int, fromHour hour: Int, minute: Int) -> (Int, Int) {
        var totalMinutes = hour * 60 + minute - minutes
        if totalMinutes < 0 { totalMinutes += 24 * 60 }
        return (totalMinutes / 60, totalMinutes % 60)
    }

    /// Identifies medication reminders that should start the DoseLuma voice
    /// session when tapped. Caregiver alerts intentionally omit this marker.
    private static let voiceReminderKey = "doseluma.voiceReminder"

    private func add(id: String, title: String, body: String, hour: Int, minute: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        content.userInfo = [Self.voiceReminderKey: true]
        var dc = DateComponents()
        dc.hour   = hour
        dc.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Without this, a notification fired while the app is frontmost is
    /// silently swallowed — the caregiver's "ding" needs to play even while
    /// they're actively looking at the app, not just when it's backgrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo[Self.voiceReminderKey] as? Bool == true {
            Task { @MainActor in
                VoiceSessionModel.shared.start()
            }
        }
        completionHandler()
    }
}
