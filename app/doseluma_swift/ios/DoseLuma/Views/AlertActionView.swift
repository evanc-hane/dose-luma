import SwiftUI

struct AlertActionView: View {
    let alert: MissedAlert
    let onAction: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Alert summary card
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("\(alert.patientName) missed their \(alert.windowName) medications")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(alert.medicationName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(alert.scheduledDate)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Action buttons
                VStack(spacing: 12) {
                    Text("What would you like to do?")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    actionButton(
                        label: "Call \(alert.patientName)",
                        icon: "phone.fill",
                        color: .green,
                        action: "called"
                    ) {
                        if let url = URL(string: "tel://\(alert.patientName)") {
                            #if os(iOS)
                            UIApplication.shared.open(url)
                            #endif
                        }
                    }

                    actionButton(
                        label: "Send Message",
                        icon: "message.fill",
                        color: .blue,
                        action: "messaged"
                    ) {
                        // Opens Messages; phone number would need to come from patient profile
                    }

                    actionButton(
                        label: "Schedule Visit",
                        icon: "figure.walk",
                        color: .purple,
                        action: "visit_scheduled"
                    ) {}

                    actionButton(
                        label: "Ask Someone to Check In",
                        icon: "person.2.fill",
                        color: .orange,
                        action: "delegated"
                    ) {}
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Respond to Alert")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") { dismiss() }
                }
            }
        }
    }

    private func actionButton(label: String, icon: String, color: Color,
                              action: String, sideEffect: @escaping () -> Void) -> some View {
        Button {
            sideEffect()
            onAction(action)
            dismiss()
        } label: {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(color)
        }
    }
}
