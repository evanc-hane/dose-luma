import Foundation

@MainActor
final class SyncService {
    static let shared = SyncService()

    private init() {
        // Load persisted deleted medication IDs
        loadDeletedMedicationIDs()
    }

    private weak var medicationStore: MedicationStore?
    private var heartbeatTask: Task<Void, Never>?
    private var isSyncInFlight = false
    private var shouldSyncImmediately = true
    private var currentScreen = "Schedule"
    private var latestVitals: [LiveVitalReading] = []
    
    // Track recent local changes to prevent server from overwriting them
    private var recentlyDeletedMedicationIDs: Set<UUID> = []
    private var deletionClearTask: Task<Void, Never>?
    
    private let deletedMedsKey = "doseluma.deleted_medication_ids"

    private var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "doseluma.device_id"), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "doseluma.device_id")
        return id
    }

    func register(store: MedicationStore) {
        medicationStore = store
        ensureHeartbeatLoop()
    }
    
    // MARK: - Persistence of Deleted IDs
    
    private func loadDeletedMedicationIDs() {
        guard let data = UserDefaults.standard.data(forKey: deletedMedsKey),
              let uuidStrings = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        recentlyDeletedMedicationIDs = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
        print("📂 SyncService: Loaded \(recentlyDeletedMedicationIDs.count) deleted medication IDs from storage")
        
        // DON'T auto-clear on startup anymore - let them accumulate
        // User can manually clear if needed, or they'll clear after successful sync confirmations
    }
    
    private func saveDeletedMedicationIDs() {
        let uuidStrings = recentlyDeletedMedicationIDs.map { $0.uuidString }
        if let data = try? JSONEncoder().encode(uuidStrings) {
            UserDefaults.standard.set(data, forKey: deletedMedsKey)
            print("💾 SyncService: Saved \(uuidStrings.count) deleted medication IDs to storage")
        }
    }
    
    /// Clear a specific medication from the deleted list (call this if server confirms deletion)
    func clearDeletedMedication(_ medicationID: UUID) {
        recentlyDeletedMedicationIDs.remove(medicationID)
        saveDeletedMedicationIDs()
        print("✅ SyncService: Cleared medication \(medicationID) from deleted tracking")
    }
    
    /// Clear all deleted medication tracking (for testing/debugging)
    func clearAllDeletedMedications() {
        print("🧹 SyncService: Clearing ALL deleted medication tracking")
        recentlyDeletedMedicationIDs.removeAll()
        saveDeletedMedicationIDs()
    }

    func updateVisibleScreen(_ screen: String) {
        currentScreen = screen
        requestImmediateSync()
    }

    func syncMedications(_ medications: [Medication]) {
        print("📤 SyncService: Syncing \(medications.count) medications to server")
        requestImmediateSync()
    }
    
    func markMedicationDeleted(_ medicationID: UUID) {
        print("🗑️ SyncService: Marking medication \(medicationID) as permanently deleted (until manually cleared)")
        recentlyDeletedMedicationIDs.insert(medicationID)
        saveDeletedMedicationIDs()
        
        // Don't auto-clear anymore - the deletion is permanent until the server properly handles it
        // or until user manually clears the deleted list
    }

    func pushAdherence(_ record: AdherenceRecord, source: AdherenceSource = .phone) {
        requestImmediateSync()
    }

    func uploadVitals(heartRate: Double?, spo2Percent: Double?, hrvMS: Double?, recordedAt: Date = Date()) {
        var readings: [LiveVitalReading] = []
        if let heartRate {
            readings.append(LiveVitalReading(type: "heart_rate", value: heartRate, unit: "bpm",
                                             recordedAt: recordedAt, source: "apple_watch"))
        }
        if let spo2Percent {
            readings.append(LiveVitalReading(type: "spo2", value: spo2Percent, unit: "percent",
                                             recordedAt: recordedAt, source: "apple_watch"))
        }
        if let hrvMS {
            readings.append(LiveVitalReading(type: "hrv_sdnn", value: hrvMS, unit: "ms",
                                             recordedAt: recordedAt, source: "apple_watch"))
        }
        latestVitals = readings
        requestImmediateSync()
    }

    func logPillScan(analysis: PillAnalysis, matches: [MedicationMatch], linkedMedicationID: UUID? = nil) {
        guard ServerConfiguration.shared.isConfigured else { return }
        let payload = PillScanLogRequest(
            deviceID: deviceID,
            medicationID: linkedMedicationID?.uuidString,
            scanType: "pill_image",
            pillAnalysis: SyncPillAnalysis(analysis),
            matches: matches.map(SyncMedicationMatch.init),
            scannedAt: Date()
        )
        Task {
            do {
                let _: SyncAckResponse = try await APIClient.shared.post("/api/scans", body: payload)
            } catch {
                debugPrint("[SyncService] pill scan log failed: \(error)")
            }
        }
    }

    private func ensureHeartbeatLoop() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncHeartbeatIfNeeded()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func requestImmediateSync() {
        shouldSyncImmediately = true
        ensureHeartbeatLoop()
    }

    private func syncHeartbeatIfNeeded() async {
        guard shouldSyncImmediately || !isSyncInFlight else { return }
        guard let medicationStore,
              ServerConfiguration.shared.isConfigured,
              let currentUser = UserSession.shared.currentUser,
              let token = UserSession.shared.token,
              !token.isEmpty else {
            return
        }
        guard !isSyncInFlight else { return }

        isSyncInFlight = true
        defer { isSyncInFlight = false }

        let snapshot = MobileSnapshotPayload(
            timeWindows: medicationStore.sortedTimeWindows.map(SyncTimeWindow.init),
            medications: medicationStore.medications.map(SyncMedication.init),
            adherenceRecords: medicationStore.adherenceRecords.map(SyncAdherenceRecord.init),
            vitals: latestVitals,
            ui: SyncUIState(
                currentScreen: currentScreen,
                activeMedicationCount: medicationStore.medications.filter(\.isActive).count,
                adherenceRecordCount: medicationStore.adherenceRecords.count,
                timeWindowCount: medicationStore.timeWindows.count
            )
        )

        let request = MobileSyncRequest(
            deviceID: deviceID,
            currentScreen: currentScreen,
            snapshot: snapshot
        )

        do {
            let response: MobileSyncResponse = try await APIClient.shared.postWithUserToken(
                "/api/mobile/sync",
                body: request,
                userToken: token
            )
            print("📥 SyncService: Received response with \(response.medications.count) medications")
            var authoritativeMeds = response.medications.compactMap(\.asMedication)
            
            // Get the IDs of medications the server is sending
            let serverMedicationIDs = Set(authoritativeMeds.map(\.id))
            
            // Check if any of our "deleted" medications are NOT in the server's list anymore
            // If so, the server has successfully processed the deletion and we can stop filtering
            var clearedDeletions: [UUID] = []
            for deletedID in recentlyDeletedMedicationIDs {
                if !serverMedicationIDs.contains(deletedID) {
                    clearedDeletions.append(deletedID)
                }
            }
            
            // Clear successfully deleted medications from our tracking
            if !clearedDeletions.isEmpty {
                for id in clearedDeletions {
                    recentlyDeletedMedicationIDs.remove(id)
                }
                saveDeletedMedicationIDs()
                print("✅ SyncService: Server confirmed \(clearedDeletions.count) deletion(s), cleared from tracking")
            }
            
            // Filter out medications that were recently deleted locally
            let beforeFilter = authoritativeMeds.count
            authoritativeMeds.removeAll { med in
                recentlyDeletedMedicationIDs.contains(med.id)
            }
            if authoritativeMeds.count < beforeFilter {
                print("🚫 SyncService: Filtered out \(beforeFilter - authoritativeMeds.count) recently deleted medication(s)")
            }
            
            let authoritativeAdherence = response.adherenceRecords.compactMap(\.asAdherenceRecord)
            let authoritativeWindows = response.timeWindows.compactMap(\.asTimeWindow)
            print("🔄 SyncService: Applying authoritative snapshot with \(authoritativeMeds.count) medications")
            medicationStore.applyAuthoritativeSnapshot(
                medications: authoritativeMeds,
                adherenceRecords: authoritativeAdherence,
                timeWindows: authoritativeWindows
            )
            if let patientName = response.patient?.displayName, !patientName.isEmpty, currentUser.displayName != patientName {
                debugPrint("[SyncService] server-authoritative profile name: \(patientName)")
            }
            shouldSyncImmediately = false
        } catch {
            if shouldForceLogout(for: error) {
                medicationStore.applyAuthoritativeSnapshot(medications: [], adherenceRecords: [], timeWindows: [])
                UserSession.shared.logout()
                debugPrint("[SyncService] device access revoked by server; logging out")
                return
            }
            debugPrint("[SyncService] heartbeat sync failed: \(error)")
        }
    }

    private func shouldForceLogout(for error: Error) -> Bool {
        guard case let APIError.httpError(statusCode, body) = error else { return false }
        guard statusCode == 401 || statusCode == 403 else { return false }

        let normalizedBody = body.lowercased()
        if normalizedBody.contains("device is no longer linked") || normalizedBody.contains("invalid or expired session") {
            return true
        }
        return false
    }
}

enum AdherenceSource: String, Encodable {
    case phone = "phone"
    case watch = "watch"
}

private struct SyncAckResponse: Decodable {
    let accepted: Int?
    let synced: Int?
    let conflicts: [String]?
}

private struct MobileSyncRequest: Encodable {
    let deviceID: String
    let currentScreen: String
    let snapshot: MobileSnapshotPayload

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case currentScreen = "current_screen"
        case snapshot
    }
}

private struct MobileSnapshotPayload: Encodable {
    let timeWindows: [SyncTimeWindow]
    let medications: [SyncMedication]
    let adherenceRecords: [SyncAdherenceRecord]
    let vitals: [LiveVitalReading]
    let ui: SyncUIState

    enum CodingKeys: String, CodingKey {
        case medications, vitals, ui
        case timeWindows = "time_windows"
        case adherenceRecords = "adherence_records"
    }
}

private struct SyncUIState: Encodable {
    let currentScreen: String
    let activeMedicationCount: Int
    let adherenceRecordCount: Int
    let timeWindowCount: Int

    enum CodingKeys: String, CodingKey {
        case currentScreen = "current_screen"
        case activeMedicationCount = "active_medication_count"
        case adherenceRecordCount = "adherence_record_count"
        case timeWindowCount = "time_window_count"
    }
}

private struct SyncTimeWindow: Encodable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
    let openHour: Int
    let openMinute: Int
    let closeHour: Int
    let closeMinute: Int
    let sortOrder: Int

    init(_ window: TimeWindow) {
        id = window.id
        name = window.name
        icon = window.icon
        colorHex = window.colorHex
        openHour = window.openHour
        openMinute = window.openMinute
        closeHour = window.closeHour
        closeMinute = window.closeMinute
        sortOrder = window.sortOrder
    }
}

private struct SyncMedication: Encodable {
    let id: String
    let name: String
    let dosage: String
    let instructions: String
    let timeWindows: [String]
    let din: String?
    let ndc: String?
    let notes: String?
    let isActive: Bool

    init(_ medication: Medication) {
        id = medication.id.uuidString
        name = medication.name
        dosage = medication.dosage
        instructions = medication.instructions
        timeWindows = medication.timeWindowIDs
        din = medication.din
        ndc = medication.ndc
        notes = medication.notes
        isActive = medication.isActive
    }
}

private struct SyncAdherenceRecord: Encodable {
    let id: String
    let medicationId: String
    let medicationName: String
    let dosage: String
    let window: String
    let scheduledDate: String
    let takenAt: String?
    let status: String
    let source: String

    init(_ record: AdherenceRecord) {
        id = record.id.uuidString
        medicationId = record.medicationId.uuidString
        medicationName = record.medicationName
        dosage = record.dosage
        window = record.windowID
        scheduledDate = ISO8601DateFormatter().string(from: record.scheduledDate)
        takenAt = record.takenAt.map { ISO8601DateFormatter().string(from: $0) }
        status = record.status.rawValue
        source = AdherenceSource.phone.rawValue
    }
}

private struct LiveVitalReading: Encodable {
    let type: String
    let value: Double
    let unit: String
    let recordedAt: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case type, value, unit, source
        case recordedAt = "recorded_at"
    }

    init(type: String, value: Double, unit: String, recordedAt: Date, source: String) {
        self.type = type
        self.value = value
        self.unit = unit
        self.recordedAt = ISO8601DateFormatter().string(from: recordedAt)
        self.source = source
    }
}

private struct MobileSyncResponse: Decodable {
    let serverTime: String?
    let patient: SyncPatientResponse?
    let timeWindows: [SyncTimeWindowResponse]
    let medications: [SyncMedicationResponse]
    let adherenceRecords: [SyncAdherenceRecordResponse]
    let vitals: [SyncVitalResponse]

    enum CodingKeys: String, CodingKey {
        case patient, medications, vitals
        case serverTime = "server_time"
        case timeWindows = "time_windows"
        case adherenceRecords = "adherence_records"
    }
}

private struct SyncPatientResponse: Decodable {
    let id: String
    let displayName: String
    let phone: String
    let role: String

    enum CodingKeys: String, CodingKey {
        case id, phone, role
        case displayName = "display_name"
    }
}

private struct SyncTimeWindowResponse: Decodable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
    let openHour: Int
    let openMinute: Int
    let closeHour: Int
    let closeMinute: Int
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case colorHex
        case openHour
        case openMinute
        case closeHour
        case closeMinute
        case sortOrder
    }

    var asTimeWindow: TimeWindow? {
        TimeWindow(
            id: id,
            name: name,
            icon: icon,
            colorHex: colorHex,
            openHour: openHour,
            openMinute: openMinute,
            closeHour: closeHour,
            closeMinute: closeMinute,
            sortOrder: sortOrder
        )
    }
}

private struct SyncMedicationResponse: Decodable {
    let id: String
    let name: String
    let dosage: String
    let instructions: String
    let timeWindows: [String]
    let din: String
    let ndc: String
    let notes: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, dosage, instructions, din, ndc, notes
        case timeWindows
        case isActive
    }

    var asMedication: Medication? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Medication(
            id: uuid,
            name: name,
            dosage: dosage,
            instructions: instructions,
            timeWindowIDs: timeWindows,
            din: din.isEmpty ? nil : din,
            ndc: ndc.isEmpty ? nil : ndc,
            notes: notes.isEmpty ? nil : notes,
            isActive: isActive
        )
    }
}

private struct SyncAdherenceRecordResponse: Decodable {
    let id: String
    let medicationId: String
    let medicationName: String
    let dosage: String
    let window: String
    let scheduledDate: String
    let takenAt: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, dosage, window, status
        case medicationId
        case medicationName
        case scheduledDate
        case takenAt
    }

    var asAdherenceRecord: AdherenceRecord? {
        guard let id = UUID(uuidString: id),
              let medicationId = UUID(uuidString: medicationId),
              let status = AdherenceStatus(rawValue: status) else {
            return nil
        }

        let scheduled = Self.dayFormatter.date(from: scheduledDate)
            ?? Self.isoFormatter.date(from: scheduledDate)
            ?? Date()
        let taken = takenAt.isEmpty ? nil : Self.isoFormatter.date(from: takenAt)

        return AdherenceRecord(
            id: id,
            medicationId: medicationId,
            medicationName: medicationName,
            dosage: dosage,
            windowID: window,
            scheduledDate: scheduled,
            takenAt: taken,
            status: status
        )
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}

private struct SyncVitalResponse: Decodable {
    let type: String
    let value: Double
    let unit: String
    let recordedAt: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case type, value, unit, source
        case recordedAt = "recorded_at"
    }
}

private struct PillScanLogRequest: Encodable {
    let deviceID: String
    let medicationID: String?
    let scanType: String
    let pillAnalysis: SyncPillAnalysis
    let matches: [SyncMedicationMatch]
    let scannedAt: String

    enum CodingKeys: String, CodingKey {
        case matches
        case deviceID = "device_id"
        case medicationID = "medication_id"
        case scanType = "scan_type"
        case pillAnalysis = "pill_analysis"
        case scannedAt = "scanned_at"
    }

    init(deviceID: String, medicationID: String?, scanType: String,
         pillAnalysis: SyncPillAnalysis, matches: [SyncMedicationMatch], scannedAt: Date) {
        self.deviceID = deviceID
        self.medicationID = medicationID
        self.scanType = scanType
        self.pillAnalysis = pillAnalysis
        self.matches = matches
        self.scannedAt = ISO8601DateFormatter().string(from: scannedAt)
    }
}

private struct SyncPillAnalysis: Encodable {
    let shape: String
    let dominantColor: String
    let secondaryColor: String?
    let imprint: String?
    let ocrText: String

    enum CodingKeys: String, CodingKey {
        case shape, imprint
        case dominantColor = "dominant_color"
        case secondaryColor = "secondary_color"
        case ocrText = "ocr_text"
    }

    init(_ analysis: PillAnalysis) {
        shape = analysis.shape.rawValue
        dominantColor = analysis.dominantColor
        secondaryColor = analysis.secondaryColor
        imprint = {
            guard let imprint = analysis.imprint, !imprint.isEmpty else { return nil }
            return imprint
        }()
        ocrText = analysis.fullText
    }
}

private struct SyncMedicationMatch: Encodable {
    let medicationID: String
    let confidence: Double
    let matchedOn: [String]

    enum CodingKeys: String, CodingKey {
        case confidence
        case medicationID = "medication_id"
        case matchedOn = "matched_on"
    }

    init(_ match: MedicationMatch) {
        medicationID = match.id.uuidString
        confidence = match.confidence
        matchedOn = [match.matchSource.rawValue]
    }
}
