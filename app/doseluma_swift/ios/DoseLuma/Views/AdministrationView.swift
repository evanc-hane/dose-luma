import SwiftUI

/// One-at-a-time medication administration workflow.
/// Each medication is presented individually with large, readable text.
/// Users can optionally scan the label via OCR before confirming administration.
struct AdministrationView: View {
    @EnvironmentObject var store: MedicationStore
    @Environment(\.dismiss) private var dismiss
    let window: TimeWindow

    @State private var showScanner  = false
    @State private var scannedText: String?
    @State private var scanVerified = false

    /// Live-computed so the list shrinks as doses are logged.
    private var pending: [Medication] { store.pendingMedications(for: window) }
    private var current: Medication?  { pending.first }
    private var total:   Int          { store.medications(for: window).count }
    private var done:    Int          { total - pending.count }

    var body: some View {
        NavigationStack {
            Group {
                if let med = current {
                    administrationStep(for: med)
                } else {
                    completionView
                }
            }
            .navigationTitle("\(window.name) Medications")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                #if os(iOS)
                OCRScannerView(detectedText: $scannedText)
                    .onDisappear { verifyScan() }
                #else
                Text("Label scanning is only available on iOS.")
                    .padding()
                #endif
            }
        }
    }

    // MARK: - Step View

    @ViewBuilder
    private func administrationStep(for med: Medication) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                // Progress indicator
                VStack(spacing: 6) {
                    ProgressView(value: Double(done), total: Double(total))
                        .tint(window.color)
                    Text("\(done) of \(total) complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // Medication card — large text for elderly users
                VStack(spacing: 18) {
                    Image(systemName: "pills.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(window.color)

                    Text(med.name)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text(med.dosage)
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    if !med.instructions.isEmpty {
                        VStack(spacing: 6) {
                            Text("Instructions")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                            Text(med.instructions)
                                .font(.title3)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if let notes = med.notes, !notes.isEmpty {
                        Label(notes, systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    if let din = med.din {
                        Label("DIN: \(din)", systemImage: "barcode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let ndc = med.ndc {
                        Label("NDC: \(ndc)", systemImage: "barcode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.thinMaterial,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal)

                // OCR verification section
                if scanVerified {
                    Label("Label verified via OCR scan", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.bold())
                } else {
                    VStack(spacing: 8) {
                        Button {
                            scannedText  = nil
                            scanVerified = false
                            showScanner  = true
                        } label: {
                            Label("Scan Label to Verify", systemImage: "camera.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(window.color)

                        Text("Optional — scan the medication bottle label to confirm identity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal)
                }

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        store.logTaken(med, window: window)
                        resetScanState()
                    } label: {
                        Label("Mark as Taken", systemImage: "checkmark.circle.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        store.logSkipped(med, window: window)
                        resetScanState()
                    } label: {
                        Label("Skip This Dose", systemImage: "forward.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    // MARK: - Completion View

    private var completionView: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 90))
                .foregroundStyle(.green)

            VStack(spacing: 10) {
                Text("All Done!")
                    .font(.largeTitle.bold())
                Text("All \(window.name.lowercased()) medications have been recorded.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .font(.title3)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func resetScanState() {
        scannedText  = nil
        scanVerified = false
    }

    /// Match scanned text against medication name, DIN, or NDC.
    private func verifyScan() {
        guard let text = scannedText, let med = current else { return }
        let lower = text.lowercased()
        let nameMatch = lower.contains(med.name.lowercased())
        let dinMatch  = med.din.map { lower.contains($0) } ?? false
        let ndcMatch  = med.ndc.map { lower.contains($0.replacingOccurrences(of: "-", with: "")) } ?? false
        scanVerified = nameMatch || dinMatch || ndcMatch
    }
}
