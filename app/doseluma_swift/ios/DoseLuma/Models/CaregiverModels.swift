import Foundation

// MARK: - Link models

struct LinkedUser: Identifiable, Decodable {
    let id: String          // link_id
    let userID: String
    let displayName: String
    let phone: String
    let linkedAt: String
    enum CodingKeys: String, CodingKey {
        case id = "link_id"
        case userID      = "user_id"
        case displayName = "display_name"
        case phone
        case linkedAt    = "linked_at"
    }
}

struct LinkListResponse: Decodable {
    let links: [LinkedUser]
}

// MARK: - Patient adherence (caregiver view)

struct PatientAdherenceRecord: Identifiable, Decodable {
    var id: String { window + medicationName }
    let medicationName: String
    let dosage: String
    let window: String
    let status: String
    let takenAt: String?
    enum CodingKeys: String, CodingKey {
        case dosage, window, status
        case medicationName = "medication_name"
        case takenAt        = "taken_at"
    }
}

struct PatientAdherenceResponse: Decodable {
    let records: [PatientAdherenceRecord]
}

struct PatientMedication: Identifiable, Decodable {
    let id: String
    let name: String
    let dosage: String
    let timeWindows: [String]
    let isActive: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, dosage
        case timeWindows = "time_windows"
        case isActive    = "is_active"
    }
}

struct PatientMedicationsResponse: Decodable {
    let medications: [PatientMedication]
}

// MARK: - Missed medication alerts

struct MissedAlert: Identifiable, Decodable {
    let id: String
    let patientID: String
    let patientName: String
    let medicationName: String
    let windowName: String
    let scheduledDate: String
    let alertedAt: String
    let action: String?
    let actionBy: String?
    let actionAt: String?
    enum CodingKeys: String, CodingKey {
        case id, action
        case patientID      = "patient_id"
        case patientName    = "patient_name"
        case medicationName = "medication_name"
        case windowName     = "window_name"
        case scheduledDate  = "scheduled_date"
        case alertedAt      = "alerted_at"
        case actionBy       = "action_by"
        case actionAt       = "action_at"
    }
    var isResolved: Bool { action != nil }
}

struct AlertListResponse: Decodable {
    let alerts: [MissedAlert]
}

struct AlertActionRequest: Encodable {
    let action: String
}
