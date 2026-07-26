import Foundation

// MARK: - FHIR R4 Models (Simplified for Medication adherence)

struct FHIRMedicationRequest: Codable {
    let resourceType: String
    let id: String?
    let status: String
    let intent: String
    let medicationCodeableConcept: FHIRCodeableConcept?
    let dosageInstruction: [FHIRDosage]?
    let identifier: [FHIRIdentifier]?
}

struct FHIRCodeableConcept: Codable {
    let coding: [FHIRCoding]?
    let text: String?
}

struct FHIRCoding: Codable {
    let system: String?
    let code: String?
    let display: String?
}

struct FHIRDosage: Codable {
    let text: String?
    let timing: FHIRTiming?
}

struct FHIRTiming: Codable {
    let code: FHIRCodeableConcept?
}

struct FHIRIdentifier: Codable {
    let system: String?
    let value: String?
}

// MARK: - PharmacySyncService

@MainActor
final class PharmacySyncService {
    static let shared = PharmacySyncService()

    private init() {}

    /// Parse a FHIR Bundle (collection of resources) and extract medications.
    func parseFHIRBundle(_ data: Data) throws -> [Medication] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["entry"] as? [[String: Any]] else {
            return []
        }

        var medications: [Medication] = []

        for item in entry {
            guard let resource = item["resource"] as? [String: Any],
                  let resourceType = resource["resourceType"] as? String,
                  resourceType == "MedicationRequest" else { continue }

            let resourceData = try JSONSerialization.data(withJSONObject: resource)
            let fhirMed = try JSONDecoder().decode(FHIRMedicationRequest.self, from: resourceData)

            // Extract Name + Identifiers (RxNorm / NDC / DIN)
            let name = fhirMed.medicationCodeableConcept?.text ??
                       fhirMed.medicationCodeableConcept?.coding?.first?.display ?? "Unknown Medication"

            var ndc: String? = nil
            var din: String? = nil

            for coding in fhirMed.medicationCodeableConcept?.coding ?? [] {
                if coding.system?.contains("ndc") == true { ndc = coding.code }
                if coding.system?.contains("din") == true { din = coding.code }
            }

            // Dosage and Timing
            let dosage = fhirMed.dosageInstruction?.first?.text ?? ""
            let timingCode = fhirMed.dosageInstruction?.first?.timing?.code?.text?.lowercased() ?? ""

            // Map FHIR timing to DoseLuma TimeWindows
            var windows: [String] = []
            if timingCode.contains("morning") || timingCode.contains("am") { windows.append("Morning") }
            if timingCode.contains("afternoon") { windows.append("Afternoon") }
            if timingCode.contains("evening") || timingCode.contains("dinner") || timingCode.contains("pm") { windows.append("Dinner") }
            if timingCode.contains("bedtime") || timingCode.contains("night") { windows.append("Bedtime") }

            // Default to Morning if none found
            if windows.isEmpty { windows.append("Morning") }

            medications.append(Medication(
                name: name,
                dosage: dosage,
                instructions: fhirMed.dosageInstruction?.first?.text ?? "",
                timeWindowIDs: windows,
                din: din,
                ndc: ndc,
                notes: "Imported via FHIR R4",
                isActive: true
            ))
        }

        return medications
    }

    func fetchPharmacyCSVData() async throws -> [Medication] {
        // Mocked CSV data fallback
        [
            Medication(
                name: "Atorvastatin",
                dosage: "10 mg",
                instructions: "Take once daily with the evening meal.",
                timeWindowIDs: ["Dinner"],
                din: nil,
                ndc: "00071-0155",
                notes: "Imported from pharmacy CSV sync.",
                isActive: true
            ),
            Medication(
                name: "Metformin",
                dosage: "500 mg",
                instructions: "Take twice daily with food.",
                timeWindowIDs: ["Morning", "Dinner"],
                din: nil,
                ndc: "00093-1048",
                notes: "Imported from pharmacy CSV sync.",
                isActive: true
            )
        ]
    }

    func fetchSimulatedPharmacyData() async throws -> [Medication] {
        // Return a mix of hardcoded and "FHIR parsed" mocks
        let fhirBundleMock = """
        {
          "resourceType": "Bundle",
          "type": "collection",
          "entry": [
            {
              "resource": {
                "resourceType": "MedicationRequest",
                "id": "medrx001",
                "status": "active",
                "intent": "order",
                "medicationCodeableConcept": {
                  "coding": [
                    { "system": "http://hl7.org/fhir/sid/ndc", "code": "00071-0155", "display": "Atorvastatin 10mg" }
                  ],
                  "text": "Atorvastatin"
                },
                "dosageInstruction": [
                  { "text": "Take 1 pill once daily in the evening", "timing": { "code": { "text": "Evening" } } }
                ]
              }
            },
            {
              "resource": {
                "resourceType": "MedicationRequest",
                "id": "medrx002",
                "status": "active",
                "intent": "order",
                "medicationCodeableConcept": {
                  "coding": [
                    { "system": "http://hl7.org/fhir/sid/ndc", "code": "00093-1048", "display": "Metformin 500mg" }
                  ],
                  "text": "Metformin"
                },
                "dosageInstruction": [
                  { "text": "Take 1 pill twice daily with meals", "timing": { "code": { "text": "Morning, Dinner" } } }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!

        return try parseFHIRBundle(fhirBundleMock)
    }
}
