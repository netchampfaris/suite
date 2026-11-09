import os
import SwiftUI
import UserNotifications

/// Asks to show notifications, and opens the link a tapped notification carries.
///
/// The site sends notifications through Frappe's notification relay, which puts the link in
/// `click_action`. The relay addresses devices by Firebase token, so delivery also needs the
/// Firebase SDK and the relay project's iOS app config. Until then the APNs token is only logged.
@MainActor
@Observable
final class Notifications: NSObject {
    /// The link of the notification the person tapped last, waiting for the signed-in app to open it.
    var opened: URL?

    /// Asks once. iOS remembers the answer and does not ask again.
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    fileprivate func registered(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Logger(subsystem: "io.frappe.suite", category: "push").info("APNs token \(hex, privacy: .private)")
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    /// Shows a notification that arrives while the app is open, as it would show when the app is closed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    // Not the async form: UIKit aborts when that one finishes off the main thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let link = response.notification.request.content.userInfo["click_action"] as? String
        // iOS calls the delegate on the main thread.
        MainActor.assumeIsolated {
            if let link { opened = URL(string: link) }
        }
        completionHandler()
    }
}

/// Sets up notifications at launch, so a tap that launched the app is not missed.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let notifications = Notifications()

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = notifications
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        notifications.registered(token)
    }
}
