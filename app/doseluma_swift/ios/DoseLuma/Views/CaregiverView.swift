import Combine
import SwiftUI

// MARK: - CaregiverViewModel

@MainActor
final class CaregiverViewModel: ObservableObject {

    @Published var patients: [LinkedUser] = []
    @Published var alerts: [MissedAlert] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func refresh() async {
        guard UserSession.shared.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            let p: LinkListResponse = try await APIClient.shared.getWithUserToken("/api/link/patients")
            let a: AlertListResponse = try await APIClient.shared.getWithUserToken("/api/alerts")
            patients = p.links
            alerts   = a.alerts.filter { !$0.isResolved }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func recordAction(alertID: String, action: String) async {
        guard let token = UserSession.shared.token else { return }
        do {
            let _: EmptyResponse = try await APIClient.shared.postWithUserToken(
                "/api/alerts/\(alertID)/action",
                body: AlertActionRequest(action: action),
                userToken: token
            )
            await refresh()
        } catch {
            debugPrint("[CaregiverVM] action error: \(error)")
        }
    }
}

// MARK: - CaregiverView

struct CaregiverView: View {
    @StateObject private var model = CaregiverViewModel()
    @State private var selectedPatient: LinkedUser?
    @State private var activeAlert: MissedAlert?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Unresolved alerts
                    if !model.alerts.isEmpty {
                        alertsSection
                    }

                    // Patients list
                    patientsSection
                }
                .padding()
                .padding(.bottom, 80)
            }
            #if os(iOS)
            .navigationTitle("My Patients")
            #endif
            .sheet(item: $selectedPatient) { patient in
                PatientDetailView(patient: patient)
            }
            .sheet(item: $activeAlert) { alert in
                AlertActionView(alert: alert) { action in
                    Task { await model.recordAction(alertID: alert.id, action: action) }
                }
            }
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
        }
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Missed Medications", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(model.alerts) { alert in
                AlertCard(alert: alert)
                    .onTapGesture { activeAlert = alert }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var patientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Patients")
                .font(.headline)

            if model.patients.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No patients yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ForEach(model.patients) { patient in
                    PatientCard(patient: patient)
                        .onTapGesture { selectedPatient = patient }
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Alert Card

struct AlertCard: View {
    let alert: MissedAlert

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.patientName)
                    .font(.subheadline.bold())
                Text("\(alert.windowName) · \(alert.medicationName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Patient Card

struct PatientCard: View {
    let patient: LinkedUser

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(patient.displayName.prefix(1)).uppercased())
                        .font(.title3.bold())
                        .foregroundStyle(.blue)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(patient.displayName)
                    .font(.subheadline.bold())
                if !patient.phone.isEmpty {
                    Text(patient.phone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }
}

