import SwiftUI
import Combine

// MARK: - Schedule View (main DoseLuma tab)

struct ScheduleView: View {
    @EnvironmentObject var store: MedicationStore
    @State private var administering: TimeWindow?
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    AdherenceRateCard(rate: store.adherenceRate(days: 7))

                    ForEach(store.sortedTimeWindows) { window in
                        TimeWindowCard(window: window, now: currentTime) {
                            administering = window
                        }
                    }
                }
                .padding()

                Spacer()
                    .frame(height: 20)
            }
            #if os(iOS)
            .navigationTitle("DoseLuma")
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Text(todayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(item: $administering) { window in
                AdministrationView(window: window)
                    .environmentObject(store)
            }
            .onReceive(timer) { _ in
                currentTime = Date()
            }
        }
    }

    private var todayText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: Date())
    }
}

// MARK: - Adherence Rate Card

struct AdherenceRateCard: View {
    let rate: Double?

    private var isOnTrack: Bool { (rate ?? 0) >= 0.8 }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("7-Day Adherence")
                    .font(.headline)
                if rate != nil {
                    Text(isOnTrack ? "On track (≥80%)" : "Needs attention (<80%)")
                        .font(.subheadline)
                        .foregroundStyle(isOnTrack ? .green : .orange)
                } else {
                    Text("No data yet — add medications to start tracking")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 7)
                if let rate {
                    Circle()
                        .trim(from: 0, to: rate)
                        .stroke(
                            isOnTrack ? Color.green : Color.orange,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Text(rate.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(rate == nil ? .secondary : .primary)
            }
            .frame(width: 60, height: 60)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Time Window Card

struct TimeWindowCard: View {
    @EnvironmentObject var store: MedicationStore
    let window: TimeWindow
    let now: Date
    let onStart: () -> Void

    private var allMeds:     [Medication] { store.medications(for: window) }
    private var pendingMeds: [Medication] { store.pendingMedications(for: window) }
    private var isActive:    Bool         { window.isCurrent(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header row
            HStack {
                Image(systemName: window.icon)
                    .foregroundStyle(window.color)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.name)
                        .font(.title3.bold())
                    Text(window.timeRangeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text("NOW")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(window.color.opacity(0.2))
                        .foregroundStyle(window.color)
                        .clipShape(Capsule())
                }
            }

            Divider()

            // Medication rows
            if allMeds.isEmpty {
                Text("No medications scheduled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(allMeds) { med in
                    MedicationStatusRow(med: med, window: window)
                }

                // Action button
                if !pendingMeds.isEmpty {
                    Button(action: onStart) {
                        Label(
                            "Administer \(pendingMeds.count) medication\(pendingMeds.count == 1 ? "" : "s")",
                            systemImage: "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                        .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(window.color)
                } else {
                    Label("All medications taken", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isActive ? window.color.opacity(0.6) : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Medication Status Row

struct MedicationStatusRow: View {
    @EnvironmentObject var store: MedicationStore
    let med: Medication
    let window: TimeWindow

    private var currentStatus: AdherenceStatus? { store.status(for: med, window: window) }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(med.name)
                    .font(.subheadline)
                Text(med.dosage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let s = currentStatus {
                Text(s.rawValue.capitalized)
                    .font(.caption.bold())
                    .foregroundStyle(dotColor)
            }
        }
    }

    private var dotColor: Color {
        switch currentStatus {
        case .taken:   return .green
        case .missed:  return .red
        case .skipped: return .orange
        case nil:      return .secondary
        }
    }
}
