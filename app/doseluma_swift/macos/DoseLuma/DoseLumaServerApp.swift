import SwiftUI

@main
struct DoseLumaServerApp: App {
    @StateObject private var store = MedicationStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(UserSession.shared)
                .environmentObject(ServerConfiguration.shared)
                .environmentObject(store)
                .onAppear {
                    WatchSessionManager.shared.activate(store: store)
                    SyncService.shared.register(store: store)
                    Task { await APIClient.shared.checkConnection() }
                    NotificationManager.shared.requestPermission()
                    BackendClient.shared.connect()
                }
                .frame(minWidth: 480, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 560, height: 800)
    }
}
