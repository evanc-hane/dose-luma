import SwiftUI

// MARK: - Time Windows Management

struct TimeWindowsManagementView: View {
    @EnvironmentObject var store: MedicationStore
    @State private var editing: TimeWindow?
    @State private var showAdd = false

    var body: some View {
        List {
            ForEach(store.sortedTimeWindows) { window in
                Button {
                    editing = window
                } label: {
                    TimeWindowRow(window: window)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteTimeWindow(window)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onMove(perform: moveWindows)
        }
        .navigationTitle("Time Windows")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            #endif
        }
        .sheet(isPresented: $showAdd) {
            TimeWindowEditorView(mode: .add)
                .environmentObject(store)
        }
        .sheet(item: $editing) { window in
            TimeWindowEditorView(mode: .edit(window))
                .environmentObject(store)
        }
    }

    private func moveWindows(from source: IndexSet, to destination: Int) {
        var windows = store.sortedTimeWindows
        windows.move(fromOffsets: source, toOffset: destination)
        for (index, var window) in windows.enumerated() {
            window.sortOrder = index
            store.updateTimeWindow(window)
        }
    }
}

// MARK: - Time Window Row

private struct TimeWindowRow: View {
    let window: TimeWindow

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: window.icon)
                .font(.title2)
                .foregroundStyle(window.color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.name)
                    .font(.body.bold())
                Text(window.timeRangeText)
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

// MARK: - Time Window Editor

struct TimeWindowEditorView: View {
    enum Mode: Identifiable {
        case add
        case edit(TimeWindow)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let w): return w.id
            }
        }
    }

    @EnvironmentObject var store: MedicationStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name = ""
    @State private var selectedIcon = "sunrise.fill"
    @State private var selectedColorHex = "#FF9500"
    @State private var opensAt = Calendar.current.date(from: DateComponents(hour: 8, minute: 0))!
    @State private var closesAt = Calendar.current.date(from: DateComponents(hour: 10, minute: 0))!

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static let iconOptions = [
        "sunrise.fill", "sun.max.fill", "sun.min.fill",
        "fork.knife", "moon.fill", "moon.stars.fill",
        "cup.and.saucer.fill", "bed.double.fill",
        "alarm.fill", "clock.fill", "leaf.fill", "drop.fill"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Lunch, Before Bed", text: $name)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.iconOptions, id: \.self) { icon in
                            Button {
                                selectedIcon = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        selectedIcon == icon
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .foregroundStyle(selectedIcon == icon ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(TimeWindowColor.allCases) { tc in
                            Button {
                                selectedColorHex = tc.rawValue
                            } label: {
                                Circle()
                                    .fill(tc.color)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary, lineWidth: selectedColorHex == tc.rawValue ? 3 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Time Range") {
                    DatePicker("Opens at", selection: $opensAt, displayedComponents: .hourAndMinute)
                    DatePicker("Closes at", selection: $closesAt, displayedComponents: .hourAndMinute)
                }
            }
            .navigationTitle(isEditing ? "Edit Window" : "New Window")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func prefill() {
        guard case .edit(let w) = mode else { return }
        name = w.name
        selectedIcon = w.icon
        selectedColorHex = w.colorHex
        opensAt = Calendar.current.date(from: DateComponents(hour: w.openHour, minute: w.openMinute))
            ?? opensAt
        closesAt = Calendar.current.date(from: DateComponents(hour: w.closeHour, minute: w.closeMinute))
            ?? closesAt
    }

    private func save() {
        let cal = Calendar.current
        let openHour = cal.component(.hour, from: opensAt)
        let openMinute = cal.component(.minute, from: opensAt)
        let closeHour = cal.component(.hour, from: closesAt)
        let closeMinute = cal.component(.minute, from: closesAt)

        switch mode {
        case .add:
            let id = generateID(from: name)
            let sortOrder = (store.timeWindows.map(\.sortOrder).max() ?? -1) + 1
            let window = TimeWindow(
                id: id,
                name: name.trimmingCharacters(in: .whitespaces),
                icon: selectedIcon,
                colorHex: selectedColorHex,
                openHour: openHour,
                openMinute: openMinute,
                closeHour: closeHour,
                closeMinute: closeMinute,
                sortOrder: sortOrder
            )
            store.addTimeWindow(window)

        case .edit(var window):
            window.name = name.trimmingCharacters(in: .whitespaces)
            window.icon = selectedIcon
            window.colorHex = selectedColorHex
            window.openHour = openHour
            window.openMinute = openMinute
            window.closeHour = closeHour
            window.closeMinute = closeMinute
            store.updateTimeWindow(window)
        }

        dismiss()
    }

    private func generateID(from name: String) -> String {
        let base = name
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        let existingIDs = Set(store.timeWindows.map(\.id))
        if !existingIDs.contains(base) { return base }
        var counter = 2
        while existingIDs.contains("\(base)_\(counter)") { counter += 1 }
        return "\(base)_\(counter)"
    }
}
