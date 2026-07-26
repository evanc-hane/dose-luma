import Combine
import SwiftUI
import HealthKit

// MARK: - Root tab view

struct ContentView: View {
    @StateObject private var session = WatchSessionManager.shared
    @StateObject private var vitals  = WatchVitalsViewModel()

    var body: some View {
        TabView {
            WatchVitalsView(vitals: vitals)
            WatchMedicationsView(session: session)
        }
        .onAppear {
            Task { await vitals.refresh() }
        }
    }
}

// MARK: - Vitals tab

struct WatchVitalsView: View {
    @ObservedObject var vitals: WatchVitalsViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Label("Vitals", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                WatchMetricTile(
                    title: "Heart Rate",
                    value: vitals.heartRate.map { "\(Int($0))" } ?? "—",
                    unit: "bpm",
                    icon: "heart.fill",
                    color: .red
                )

                WatchMetricTile(
                    title: "SpO₂",
                    value: vitals.spo2.map { String(format: "%.0f", $0) } ?? "—",
                    unit: "%",
                    icon: "lungs.fill",
                    color: .blue
                )

                WatchMetricTile(
                    title: "HRV",
                    value: vitals.hrv.map { String(format: "%.0f", $0) } ?? "—",
                    unit: "ms",
                    icon: "waveform.path.ecg",
                    color: .green
                )

                if vitals.isLoading {
                    ProgressView()
                        .padding(.top, 4)
                }

                Button {
                    Task { await vitals.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .disabled(vitals.isLoading)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Metric tile

struct WatchMetricTile: View {
    let title: String
    let value: String
    let unit:  String
    let icon:  String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).bold())
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Medications tab

struct WatchMedicationsView: View {
    @ObservedObject var session: WatchSessionManager

    private var pending: [WCMedication] {
        session.medications.filter { $0.isPending }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Label("Medications", systemImage: "pills.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                if pending.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("All done!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                } else {
                    ForEach(pending) { med in
                        WatchMedCard(med: med, session: session)
                    }
                }

                Button {
                    session.requestSchedule()
                } label: {
                    Label("Sync", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Medication card

struct WatchMedCard: View {
    let med:     WCMedication
    @ObservedObject var session: WatchSessionManager
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(med.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text(med.dosage.isEmpty ? med.windowRaw : med.dosage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(med.windowRaw)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button {
                    WKInterfaceDevice.current().play(.success)
                    session.markTaken(medication: med)
                } label: {
                    Label("Taken", systemImage: "checkmark")
                        .font(.caption2.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    WKInterfaceDevice.current().play(.failure)
                    session.markSkipped(medication: med)
                } label: {
                    Label("Skip", systemImage: "xmark")
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Watch vitals view model (reads HealthKit directly from Watch)

@MainActor
final class WatchVitalsViewModel: ObservableObject {

    @Published var heartRate: Double?
    @Published var spo2:      Double?
    @Published var hrv:       Double?
    @Published var isLoading  = false

    private let hkStore = HKHealthStore()

    private let readTypes: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
    ]

    func refresh() async {
        isLoading = true
        do {
            try await hkStore.requestAuthorization(toShare: [], read: readTypes)

            async let hrSamples   = latest(.heartRate,                unit: HKUnit.count().unitDivided(by: .minute()))
            async let spo2Samples = latest(.oxygenSaturation,         unit: .percent())
            async let hrvSamples  = latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))

            let (hr, spo2, hrv) = try await (hrSamples, spo2Samples, hrvSamples)
            heartRate = hr
            self.spo2 = spo2.map { $0 * 100 }
            self.hrv  = hrv
        } catch {
            // Silently ignore on Watch — user will see "—"
        }
        isLoading = false
    }

    private func latest(_ id: HKQuantityTypeIdentifier,
                        unit: HKUnit) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(
            withStart: Calendar.current.date(byAdding: .hour, value: -6, to: Date()),
            end: Date()
        )
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                let value = (samples as? [HKQuantitySample])?.first?.quantity.doubleValue(for: unit)
                cont.resume(returning: value)
            }
            self.hkStore.execute(q)
        }
    }
}
