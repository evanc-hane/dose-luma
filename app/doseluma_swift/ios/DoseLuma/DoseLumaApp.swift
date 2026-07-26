import SwiftUI
import UIKit

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            UserSession.shared.registerPushToken(hexToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        debugPrint("[APNs] registration failed: \(error)")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.newData)
    }
}

// MARK: - App Entry Point

@main
struct DoseLumaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                    UIApplication.shared.registerForRemoteNotifications()
                    NotificationManager.shared.requestPermission()
                    BackendClient.shared.connect()
                }
        }
    }
}
