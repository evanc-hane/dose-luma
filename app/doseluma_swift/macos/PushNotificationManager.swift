import Foundation
import UserNotifications

/// Manages push notifications for missed medication alerts
final class PushNotificationManager: @unchecked Sendable {
    static let shared = PushNotificationManager()
    
    private let db: Database
    
    private init() {
        self.db = Database.shared
    }
    
    /// Send push notification to caregivers when a patient misses a dose
    func notifyCaregivers(
        patientId: String,
        patientName: String,
        medicationName: String,
        window: String
    ) async {
        do {
            // Find all caregivers linked to this patient
            let caregivers = try db.query(
                """
                SELECT u.id, u.display_name, pt.device_token, pt.platform
                FROM users u
                JOIN caregiver_links cl ON cl.caregiver_id = u.id
                LEFT JOIN push_tokens pt ON pt.user_id = u.id
                WHERE cl.patient_id = ? AND cl.status = 'active' AND pt.device_token IS NOT NULL
                """,
                params: [patientId]
            )
            
            guard !caregivers.isEmpty else {
                ServerLogger.shared.log(.system, message: "No caregivers with push tokens for patient \(patientName)")
                return
            }
            
            // Send notification to each caregiver
            for caregiver in caregivers {
                guard let deviceToken = caregiver["device_token"],
                      let caregiverName = caregiver["display_name"] else {
                    continue
                }
                
                let title = "Missed Medication Alert"
                let body = "\(patientName) missed their \(medicationName) (\(window))"
                
                await sendPushNotification(
                    deviceToken: deviceToken,
                    title: title,
                    body: body,
                    data: [
                        "type": "missed_dose",
                        "patient_id": patientId,
                        "patient_name": patientName,
                        "medication_name": medicationName,
                        "window": window
                    ]
                )
                
                ServerLogger.shared.log(
                    .push,
                    message: "Notified caregiver \(caregiverName) about missed dose for \(patientName)"
                )
            }
        } catch {
            ServerLogger.shared.log(.error, message: "Failed to notify caregivers: \(error.localizedDescription)")
        }
    }
    
    /// Send a local notification (for testing on the same device)
    func sendLocalNotification(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        content.categoryIdentifier = "MISSED_MEDICATION"
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            ServerLogger.shared.log(.error, message: "Local notification failed: \(error.localizedDescription)")
        }
    }
    
    /// Send remote push notification via APNs
    /// NOTE: This is a placeholder. In production, you would integrate with:
    /// - Apple Push Notification service (APNs) for iOS
    /// - Firebase Cloud Messaging (FCM) for cross-platform
    /// - A backend service like AWS SNS or OneSignal
    private func sendPushNotification(
        deviceToken: String,
        title: String,
        body: String,
        data: [String: String]
    ) async {
        // TODO: Implement actual push notification sending
        // For now, log what would be sent
        ServerLogger.shared.log(
            .push,
            message: "Would send push: '\(title)' - '\(body)' to token \(deviceToken.prefix(8))..."
        )
        
        // Example of what you would do with APNs:
        /*
        let payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": title,
                    "body": body
                ],
                "sound": "default",
                "badge": 1,
                "category": "MISSED_MEDICATION"
            ],
            "data": data
        ]
        
        // Send to APNs using URLSession or a library like APNSwift
        // https://github.com/kylebrowning/APNSwift
        */
        
        // For local development/testing, send a local notification instead
        await sendLocalNotification(title: title, body: body)
    }
}

// MARK: - Notification Categories

extension PushNotificationManager {
    /// Register notification categories for interactive notifications
    static func registerNotificationCategories() {
        let callAction = UNNotificationAction(
            identifier: "CALL_PATIENT",
            title: "Call Patient",
            options: [.foreground]
        )
        
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )
        
        let category = UNNotificationCategory(
            identifier: "MISSED_MEDICATION",
            actions: [callAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
