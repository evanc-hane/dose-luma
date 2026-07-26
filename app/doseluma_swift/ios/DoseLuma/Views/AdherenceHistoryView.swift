import SwiftUI

// MARK: - Adherence History

struct AdherenceHistoryView: View {
    @EnvironmentObject var store: MedicationStore
    @State private var selectedDate = Date()

    /// Last 7 days, oldest → newest.
    private var last7Days: [Date] {
        (0..<7)
            .compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
            .reversed()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    overallSummarySection
                    weekStrip
                    dayDetailSection
                }
                .padding()

                Spacer()
                    .frame(height: 60)
            }
            #if os(iOS)
            .navigationTitle("Adherence History")
            #endif
        }
    }

    // MARK: Overall summary

    private var overallSummarySection: some View {
        HStack(spacing: 16) {
            summaryTile(value: store.adherenceRate(days: 7).map  { "\(Int($0 * 100))%" } ?? "—",
                        label: "7-Day Rate",
                        color: store.adherenceRate(days: 7).map  { $0 >= 0.8 ? Color.green : .orange } ?? .secondary)
            summaryTile(value: store.adherenceRate(days: 30).map { "\(Int($0 * 100))%" } ?? "—",
                        label: "30-Day Rate",
                        color: store.adherenceRate(days: 30).map { $0 >= 0.8 ? Color.green : .orange } ?? .secondary)
            summaryTile(value: "\(store.medications.filter { $0.isActive }.count)",
                        label: "Active Meds",
                        color: .blue)
        }
    }

    private func summaryTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Week strip

    private var weekStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Past 7 Days")
                .font(.headline)

            HStack(spacing: 6) {
                ForEach(last7Days, id: \.self) { date in
                    DayDot(
                        date: date,
                        records: store.recordsForDay(date),
                        isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDate)
                    )
                    .onTapGesture { selectedDate = date }
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Day detail

    private var dayDetailSection: some View {
        let records = store.recordsForDay(selectedDate)
        let header  = Calendar.current.isDateInToday(selectedDate)
            ? "Today"
            : DateFormatter.localizedString(from: selectedDate, dateStyle: .medium, timeStyle: .none)

        return VStack(alignment: .leading, spacing: 12) {
            Text(header)
                .font(.headline)

            if records.isEmpty {
                Text("No records for this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // Group by window
                ForEach(store.sortedTimeWindows) { window in
                    let windowRecords = records.filter { $0.windowID == window.id }
                    if !windowRecords.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(window.name, systemImage: window.icon)
                                .font(.subheadline.bold())
                                .foregroundStyle(window.color)
                            ForEach(windowRecords) { r in
                                AdherenceRecordRow(record: r)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Day Dot

struct DayDot: View {
    let date: Date
    let records: [AdherenceRecord]
    let isSelected: Bool

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "E"
        return String(f.string(from: date).prefix(1))
    }

    private var dayNumber: String {
        Calendar.current.component(.day, from: date).description
    }

    private var dotColor: Color {
        guard !records.isEmpty else { return Color.secondary.opacity(0.25) }
        let rate = Double(records.filter { $0.status == .taken }.count) / Double(records.count)
        if rate >= 0.8  { return .green }
        if rate >= 0.5  { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(dayLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Circle()
                .fill(dotColor)
                .frame(width: 30, height: 30)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                )
                .overlay(
                    Text(dayNumber)
                        .font(.caption2.bold())
                        .foregroundStyle(records.isEmpty ? Color.secondary : Color.white)
                )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Adherence Record Row

struct AdherenceRecordRow: View {
    let record: AdherenceRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.medicationName)
                    .font(.subheadline)
                Text(record.dosage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                statusBadge
                if let t = record.takenAt {
                    Text(shortTime(t))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch record.status {
            case .taken:   return ("Taken",   .green)
            case .missed:  return ("Missed",  .red)
            case .skipped: return ("Skipped", .orange)
            }
        }()
        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }
}
