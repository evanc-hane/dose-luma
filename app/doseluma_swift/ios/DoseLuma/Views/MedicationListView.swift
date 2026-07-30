import SwiftUI

// MARK: - Navigation destinations for the medication tab

/// Pushed inline within this tab's own NavigationStack instead of presented
/// as a separate sheet/window — editing an existing medication or adding a
/// new one both just become another page in the same navigation flow.
enum MedRoute: Hashable {
    case edit(Medication)
    case new
}

// MARK: - Medication List

struct MedicationListView: View {
    @EnvironmentObject var store: MedicationStore

    @State private var path: [MedRoute] = []
    @State private var showScanLabel = false
    @State private var showScanPill = false
    @State private var isSyncing = false

    @State private var scannedLabelText: String?
    @State private var scannedPillAnalysis: PillAnalysis?

    // Track whether we should auto-show add view after scan completes
    @State private var shouldAutoShowAdd = false

    var body: some View {
        NavigationStack(path: $path) {
            medicationContent
                #if os(iOS)
                .navigationTitle("Medications")
                #endif
                .toolbar { toolbarContent }
                .navigationDestination(for: MedRoute.self) { route in
                    switch route {
                    case .edit(let med):
                        AddMedicationView(editing: med)
                            .environmentObject(store)
                    case .new:
                        AddMedicationView(
                            initialOCR: scannedLabelText,
                            initialPill: scannedPillAnalysis
                        )
                        .environmentObject(store)
                        .onDisappear {
                            scannedLabelText = nil
                            scannedPillAnalysis = nil
                            shouldAutoShowAdd = false
                        }
                    }
                }
                .sheet(isPresented: $showScanLabel) {
                    #if os(iOS)
                    OCRScannerView(detectedText: $scannedLabelText)
                    #else
                    Text("Label scanning is only available on iOS.")
                        .padding()
                    #endif
                }
                .sheet(isPresented: $showScanPill) {
                    #if os(iOS)
                    PillScannerView(result: $scannedPillAnalysis)
                    #else
                    Text("Pill scanning is only available on iOS.")
                        .padding()
                    #endif
                }
                .onChange(of: scannedLabelText) { _, newValue in
                    if shouldAutoShowAdd, newValue != nil {
                        path.append(.new)
                        shouldAutoShowAdd = false
                    }
                }
                .onChange(of: scannedPillAnalysis) { _, newValue in
                    if shouldAutoShowAdd, newValue != nil {
                        path.append(.new)
                        shouldAutoShowAdd = false
                    }
                }
                .onChange(of: showScanLabel) { _, isPresenting in
                    if isPresenting { shouldAutoShowAdd = true }
                }
                .onChange(of: showScanPill) { _, isPresenting in
                    if isPresenting { shouldAutoShowAdd = true }
                }
        }
    }

    // MARK: - View Components

    private var medicationContent: some View {
        Group {
            if store.medications.isEmpty {
                emptyStateView
            } else {
                medicationList
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "pills")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Medications")
                .font(.headline)
            Text("Tap + to add your first medication.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var medicationList: some View {
        List {
            ForEach(store.medications) { med in
                Button { path.append(.edit(med)) } label: {
                    MedicationRow(med: med)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.delete(med)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        var updated = med
                        updated.isActive.toggle()
                        store.update(updated)
                    } label: {
                        Label(
                            med.isActive ? "Pause" : "Resume",
                            systemImage: med.isActive ? "pause.circle" : "play.circle"
                        )
                    }
                    .tint(med.isActive ? .orange : .green)
                }
            }
            .onDelete { indexSet in
                indexSet.forEach { index in
                    let med = store.medications[index]
                    store.delete(med)
                }
            }
            Section { EmptyView() } footer: {
                Spacer().frame(height: 60)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { showScanLabel = true } label: {
                    Label("Scan Label (OCR)", systemImage: "camera.viewfinder")
                }
                Button { showScanPill = true } label: {
                    Label("Scan Pill (Image)", systemImage: "pill.circle")
                }
                Button { syncFromCSV() } label: {
                    Label("Sync Pharmacy (CSV)", systemImage: "filemenu.and.selection")
                }
                Button { syncFromFHIR() } label: {
                    Label("Sync Pharmacy (FHIR)", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                }
                Button { path.append(.new) } label: {
                    Label("Manual Entry", systemImage: "keyboard")
                }
            } label: {
                if isSyncing {
                    ProgressView().progressViewStyle(.circular)
                } else {
                    Image(systemName: "plus")
                }
            }
        }
    }

    // MARK: - Sync Methods

    private func syncFromCSV() {
        Task {
            isSyncing = true
            defer { isSyncing = false }
            do {
                let medications = try await PharmacySyncService.shared.fetchPharmacyCSVData()
                for medication in medications {
                    store.add(medication)
                }
            } catch {
                print("CSV Sync Error: \(error)")
            }
        }
    }

    private func syncFromFHIR() {
        Task {
            isSyncing = true
            defer { isSyncing = false }
            do {
                let medications = try await PharmacySyncService.shared.fetchSimulatedPharmacyData()
                for medication in medications {
                    store.add(medication)
                }
            } catch {
                print("FHIR Sync Error: \(error)")
            }
        }
    }
}

// MARK: - Medication Row

struct MedicationRow: View {
    @EnvironmentObject var store: MedicationStore
    let med: Medication

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(med.name)
                    .font(.headline)
                Spacer()
                if !med.isActive {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(med.dosage.isEmpty ? "No dosage specified" : med.dosage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !med.timeWindowIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(med.timeWindowIDs, id: \.self) { windowID in
                            if let w = store.timeWindow(byID: windowID) {
                                Label(w.name, systemImage: w.icon)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(w.color.opacity(0.15))
                                    .foregroundStyle(w.color)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(med.isActive ? 1.0 : 0.5)
    }
}
