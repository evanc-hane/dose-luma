import SwiftUI
import Foundation

// MARK: - Onboarding Flow
//
// No passwords, no accounts — identify yourself by name (the "Walled Garden"
// philosophy: security lives at the network boundary, not inside it).
//   Connect to the fixed backend → choose role → enter name → Main app

struct OnboardingView: View {
    @EnvironmentObject private var config: ServerConfiguration
    @EnvironmentObject private var session: UserSession
    @State private var step: OnboardingStep = .welcome
    @State private var selectedRole: UserRole = .patient

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case connectServer = 1
        case chooseRole = 2
        case createProfile = 3
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeStepView { step = .connectServer }
            case .connectServer:
                ConnectServerStepView(onConnected: {
                    step = .chooseRole
                }, onBack: {
                    step = .welcome
                })
            case .chooseRole:
                ChooseRoleStepView(selectedRole: $selectedRole) {
                    step = .createProfile
                }
            case .createProfile:
                CreateProfileStepView(role: selectedRole) {
                    step = .chooseRole
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "pills.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            VStack(spacing: 12) {
                Text("Welcome to DoseLuma")
                    .font(.largeTitle.bold())
                Text("Secure medication adherence tracking.\nNo passwords — just your name.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Label("Get Started", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Scan a QR code from a caregiver,\nor just tell us your name to get started.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Step 2: Connect to Server
//
// DoseLuma has one fixed backend address (ServerConfiguration.fixedHost/
// fixedPort) — there is intentionally no UI for entering or changing a
// server address. This step just checks reachability and gates on it.

private struct ConnectServerStepView: View {
    let onConnected: () -> Void
    var onBack: (() -> Void)?

    @EnvironmentObject private var config: ServerConfiguration

    var body: some View {
        Group {
            switch config.connectionStatus {
                case .connected:
                    VStack(spacing: 24) {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                        VStack(spacing: 8) {
                            Text("Connected to Server")
                                .font(.title2.bold())
                            Text(config.activeHost.isEmpty ? config.host : config.activeHost)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(spacing: 12) {
                            Button(action: onConnected) {
                                Text("Continue")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        .padding(.bottom, 40)
                    }
                    .padding(.horizontal, 32)

                case .checking:
                    VStack(spacing: 20) {
                        Spacer()
                        ProgressView()
                            .controlSize(.large)
                        Text("Connecting to \(config.host)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                case .unreachable(let reason):
                    notConnectedView(reason: reason)
                case .authFailed:
                    notConnectedView(reason: "Authentication failed.")
                case .notConfigured:
                    notConnectedView(reason: nil)
            }
        }
        .onAppear { recheck() }
    }

    private func notConnectedView(reason: String?) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            VStack(spacing: 8) {
                Text("Not Connected")
                    .font(.title2.bold())
                Text("\(config.host):\(config.port)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            Spacer()
            VStack(spacing: 12) {
                Button(action: recheck) {
                    Text("Retry")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Back") { onBack?() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 32)
    }

    private func recheck() {
        guard config.isConfigured else {
            config.connectionStatus = .notConfigured
            return
        }
        Task { await APIClient.shared.checkConnection() }
    }
}

// MARK: - Step 3: Choose Role

private struct ChooseRoleStepView: View {
    @Binding var selectedRole: UserRole
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("How will you use DoseLuma?")
                    .font(.title2.bold())
                Text("Choose what best describes you.\nYou can change this later in your profile.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                ForEach(UserRole.allCases, id: \.self) { role in
                    RoleOptionCard(
                        role: role,
                        isSelected: selectedRole == role
                    ) {
                        selectedRole = role
                    }
                }
            }
            .padding(.vertical)

            Spacer()

            Button(action: onContinue) {
                Text("Continue as \(selectedRole.label)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 24)
    }
}

private struct RoleOptionCard: View {
    let role: UserRole
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                Image(systemName: role.icon)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(isSelected ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(Circle())
                    .foregroundStyle(isSelected ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(role.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(role.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 4: Create Profile

private struct CreateProfileStepView: View {
    let role: UserRole
    let onBack: () -> Void
    @EnvironmentObject private var session: UserSession

    @State private var displayName = ""
    @State private var phone       = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: role.icon)
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        Text("What's your name?")
                            .font(.title2.bold())
                        Text("To get started, tell us your name.\nIf you've used DoseLuma before, use the same name to see your data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    VStack(spacing: 14) {
                        TextField("Your Name (e.g. John Doe)", text: $displayName)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        TextField("Phone Number (optional)", text: $phone)
                            #if os(iOS)
                            .keyboardType(.phonePad)
                            #endif
                            .multilineTextAlignment(.center)
                    }

                    if let err = session.errorMessage {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button(action: submit) {
                            Group {
                                if session.isLoading {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Start Using DoseLuma")
                                        .font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(session.isLoading)

                        Button("Back") { onBack() }
                            .font(.subheadline)
                            .disabled(session.isLoading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }

    private func submit() {
        session.errorMessage = nil
        guard !displayName.isEmpty else {
            session.errorMessage = "Please enter your name to continue."
            return
        }
        Task {
            // Register will now auto-login if the name exists
            await session.register(
                username: displayName, // use name as username too for simplicity
                displayName: displayName,
                phone: phone,
                password: "",
                role: role
            )
        }
    }
}
