import Combine
import SwiftUI
#if os(iOS)
import HealthKit
#endif

// MARK: - Root View
//
// Gates the entire app behind the onboarding flow.
// Once onboarding is complete (server configured + user logged in),
// shows role-adaptive tabs.

struct ContentView: View {
    @EnvironmentObject private var session: UserSession
    @EnvironmentObject private var config: ServerConfiguration

    var body: some View {
        if session.hasCompletedOnboarding {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}

// MARK: - Main Tab View (role-adaptive)

struct MainTabView: View {
    @EnvironmentObject private var session: UserSession
    @ObservedObject private var backendClient = BackendClient.shared
    @State private var selectedTab: Tab = .schedule

    private enum Tab: Hashable {
        case schedule
        case history
        case medications
        case vitals
        case voice
        case caregiver
        case profile
    }

    private var role: UserRole {
        session.currentUser?.role ?? .patient
    }

    private struct TabInfo {
        let tab: Tab
        let title: String
        let systemImage: String
        let content: AnyView
    }

    private var tabs: [TabInfo] {
        var items: [TabInfo] = []
        if role.showsPatientTabs {
            items += [
                TabInfo(tab: .schedule, title: "Schedule", systemImage: "calendar.badge.clock", content: AnyView(ScheduleView())),
                TabInfo(tab: .history, title: "History", systemImage: "chart.bar.fill", content: AnyView(AdherenceHistoryView())),
                TabInfo(tab: .medications, title: "Medications", systemImage: "pills.fill", content: AnyView(MedicationListView())),
                TabInfo(tab: .vitals, title: "Vitals", systemImage: "heart.fill", content: AnyView(VitalsView())),
                TabInfo(tab: .voice, title: "Voice", systemImage: "waveform", content: AnyView(VoiceView())),
            ]
        }
        if role.showsCaregiverTab {
            items.append(TabInfo(tab: .caregiver, title: "My Patients", systemImage: "person.2.fill", content: AnyView(CaregiverView())))
        }
        items.append(TabInfo(tab: .profile, title: "Profile", systemImage: "person.crop.circle.fill", content: AnyView(ProfileView())))
        return items
    }

    var body: some View {
        content
            .onAppear {
                if !role.showsPatientTabs && role.showsCaregiverTab {
                    selectedTab = .caregiver
                }
                SyncService.shared.updateVisibleScreen(screenName(for: selectedTab))
            }
            .onChange(of: selectedTab) { newValue in
                SyncService.shared.updateVisibleScreen(screenName(for: newValue))
            }
            .onChange(of: backendClient.pendingCheckIn) { checkIn in
                // Scheduled check-in fired server-side (scheduler.py) and the
                // agent is already in the room — jump to Voice and join it,
                // same as if the patient had pressed the call button.
                guard checkIn != nil, role.showsPatientTabs else { return }
                selectedTab = .voice
                VoiceSessionModel.shared.start()
                backendClient.pendingCheckIn = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // Native TabView on macOS collapses extra tabs into a ">>" overflow
        // dropdown once the window narrows — a custom horizontal strip stays
        // horizontal (scrolling instead of collapsing) at any window width.
        VStack(spacing: 0) {
            macOSTabBar
            Divider()
            ZStack {
                ForEach(tabs, id: \.tab) { info in
                    info.content
                        .opacity(selectedTab == info.tab ? 1 : 0)
                        .allowsHitTesting(selectedTab == info.tab)
                }
            }
        }
        #else
        TabView(selection: $selectedTab) {
            ForEach(tabs, id: \.tab) { info in
                info.content
                    .tag(info.tab)
                    .tabItem { Label(info.title, systemImage: info.systemImage) }
            }
        }
        #endif
    }

    #if os(macOS)
    // Every tab gets an equal-width share of the full window width (like a
    // segmented control) — the highlight fills that entire section, not just
    // a box hugging the label, so clicking anywhere in the section selects it.
    private var macOSTabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.tab) { info in
                Button {
                    selectedTab = info.tab
                } label: {
                    Label(info.title, systemImage: info.systemImage)
                        .font(.subheadline.weight(selectedTab == info.tab ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedTab == info.tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .foregroundStyle(selectedTab == info.tab ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
    #endif

    private func screenName(for tab: Tab) -> String {
        switch tab {
        case .schedule: return "Schedule"
        case .history: return "Adherence History"
        case .medications: return "Medications"
        case .vitals: return "Vitals"
        case .voice: return "Voice"
        case .caregiver: return "Caregiver"
        case .profile: return "Profile"
        }
    }
}

// MARK: - HealthKit Vitals (preserved from original app)
//
// HealthKit is iOS-only — macOS gets a placeholder VitalsView below.

#if os(iOS)

final class HealthStore {
    private let healthStore = HKHealthStore()

    private let readTypes: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
    ]

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Health data not available on this device."])
        }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchQuantitySamples(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!,
        to endDate: Date = Date()
    ) async throws -> [(date: Date, value: Double)] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let results: [(Date, Double)] = (samples as? [HKQuantitySample])?.map {
                    ($0.endDate, $0.quantity.doubleValue(for: unit))
                } ?? []
                continuation.resume(returning: results)
            }
            self.healthStore.execute(query)
        }
    }
}

@MainActor
final class VitalsViewModel: ObservableObject {

    private let store = HealthStore()

    @Published var heartRate: Double?
    @Published var spo2Percent: Double?
    @Published var hrvMS: Double?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func refresh() async {
        isLoading    = true
        errorMessage = nil
        do {
            try await store.requestAuthorization()
            async let hrValues   = store.fetchQuantitySamples(identifier: .heartRate,
                                                              unit: HKUnit.count().unitDivided(by: .minute()))
            async let spo2Values = store.fetchQuantitySamples(identifier: .oxygenSaturation, unit: .percent())
            async let hrvValues  = store.fetchQuantitySamples(identifier: .heartRateVariabilitySDNN,
                                                              unit: .secondUnit(with: .milli))
            let (hr, spo2, hrv) = try await (hrValues, spo2Values, hrvValues)
            heartRate   = hr.last?.value
            spo2Percent = (spo2.last?.value).map { $0 * 100.0 }
            hrvMS       = hrv.last?.value
            SyncService.shared.uploadVitals(heartRate: heartRate,
                                            spo2Percent: spo2Percent,
                                            hrvMS: hrvMS)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct VitalsView: View {
    @StateObject private var model = VitalsViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 36))
                    Text("Latest from Apple Watch")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Group {
                    MetricRow(title: "Heart Rate",
                              valueText: model.heartRate.map { "\(Int($0)) bpm" } ?? "---")
                    MetricRow(title: "SpO2",
                              valueText: model.spo2Percent.map { String(format: "%.0f%%", $0) } ?? "---")
                    MetricRow(title: "HRV (SDNN)",
                              valueText: model.hrvMS.map { String(format: "%.0f ms", $0) } ?? "---")
                }
                .redacted(reason: model.isLoading ? .placeholder : [])

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                Spacer(minLength: 0)

                Button(action: { Task { await model.refresh() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading)
            }
            .padding()
            .navigationTitle("Vitals")
            .task { await model.refresh() }
        }
    }
}

struct MetricRow: View {
    let title: String
    let valueText: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(valueText)
                .font(.system(.title3, design: .rounded))
                .monospacedDigit()
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#else

struct VitalsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Vitals sync from Apple Watch/HealthKit is only available on iOS.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

#endif

#Preview {
    ContentView()
}
