import SwiftUI

// MARK: - Profile View
//
// Shows the logged-in user's profile info, role, linked people, and logout.

struct ProfileView: View {
    @EnvironmentObject private var session: UserSession
    @State private var showLogoutConfirm = false
    @State private var phoneInput = ""

    var body: some View {
        NavigationStack {
            List {
                // Profile header
                Section {
                    if let user = session.currentUser {
                        HStack(spacing: 16) {
                            Circle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 60, height: 60)
                                .overlay(
                                    Text(String(user.displayName.prefix(1)).uppercased())
                                        .font(.title.bold())
                                        .foregroundStyle(.blue)
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.displayName)
                                    .font(.title3.bold())
                                Text("@\(user.username)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Label(user.role.label, systemImage: user.role.icon)
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Contact info — editable
                if let user = session.currentUser {
                    Section {
                        TextField("Phone number", text: $phoneInput)
                            #if os(iOS)
                            .keyboardType(.phonePad)
                            #endif
                            .onAppear { phoneInput = user.phone }
                            .onSubmit {
                                session.updatePhoneNumber(phoneInput.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                    } header: {
                        Text("Contact")
                    } footer: {
                        Text("Tap Return to save your phone number")
                    }
                }

                // Role info
                if let user = session.currentUser {
                    Section {
                        HStack {
                            Image(systemName: user.role.icon)
                                .foregroundStyle(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.role.label)
                                    .font(.body)
                                Text(user.role.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Role")
                    }
                }

                // Account actions
                Section {
                    Button("Log Out", role: .destructive) {
                        showLogoutConfirm = true
                    }
                }
            }
            #if os(iOS)
            .navigationTitle("Profile")
            #endif
            .confirmationDialog("Log Out?", isPresented: $showLogoutConfirm) {
                Button("Log Out", role: .destructive) {
                    session.logout()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need to log in again to use DoseLuma.")
            }
        }
    }
}
