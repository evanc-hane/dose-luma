import Combine
import SwiftUI

@MainActor
final class PatientDetailViewModel: ObservableObject {

    @Published var todayRecords: [PatientAdherenceRecord] = []
    @Published var medications: [PatientMedication] = []
    @Published var isLoading = false

    let patient: LinkedUser

    init(patient: LinkedUser) {
        self.patient = patient
    }

    func load() async {
        isLoading = true
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        do {
            let adh: PatientAdherenceResponse = try await APIClient.shared.getWithUserToken(
                "/api/patients/\(patient.userID)/adherence?date=\(today)"
            )
            let meds: PatientMedicationsResponse = try await APIClient.shared.getWithUserToken(
                "/api/patients/\(patient.userID)/medications"
            )
            todayRecords = adh.records
            medications  = meds.medications.filter { $0.isActive }
        } catch {
            debugPrint("[PatientDetail] load error: \(error)")
        }
        isLoading = false
    }
}

struct PatientDetailView: View {
    let patient: LinkedUser
    @StateObject private var model: PatientDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(patient: LinkedUser) {
        self.patient = patient
        _model = StateObject(wrappedValue: PatientDetailViewModel(patient: patient))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Contact actions
                    contactBar

                    // Today's adherence
                    todaySection

                    // Medication list
                    medicationsSection
                }
                .padding()
                .padding(.bottom, 80)
            }
            .navigationTitle(patient.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .redacted(reason: model.isLoading ? .placeholder : [])
        }
    }

    private var contactBar: some View {
        HStack(spacing: 16) {
            if !patient.phone.isEmpty {
                contactButton(label: "Call", icon: "phone.fill", color: .green) {
                    guard let url = URL(string: "tel://\(patient.phone.filter { $0.isNumber })") else { return }
                    #if os(iOS)
                    UIApplication.shared.open(url)
                    #endif
                }
                contactButton(label: "Message", icon: "message.fill", color: .blue) {
                    guard let url = URL(string: "sms:\(patient.phone.filter { $0.isNumber })") else { return }
                    #if os(iOS)
                    UIApplication.shared.open(url)
                    #endif
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func contactButton(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Schedule")
                .font(.headline)

            if model.todayRecords.isEmpty {
                Text("No data for today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.todayRecords) { record in
                    HStack {
                        Circle()
                            .fill(statusColor(record.status))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.medicationName)
                                .font(.subheadline)
                            Text(record.window.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.status.capitalized)
                            .font(.caption.bold())
                            .foregroundStyle(statusColor(record.status))
                    }
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var medicationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Medications")
                .font(.headline)

            if model.medications.isEmpty {
                Text("No active medications.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.medications) { med in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(med.name).font(.subheadline)
                            Text(med.dosage).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(med.timeWindows.map { $0.capitalized }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "taken":   return .green
        case "missed":  return .red
        case "skipped": return .orange
        default:        return .secondary
        }
    }
}
