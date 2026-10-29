import Foundation
import UserNotifications

/// System notifications from Cubi. Off by default: the user's own Notification hook already
/// notifies, so this stays quiet until they switch over. Clicking one focuses the session's
/// terminal, like the old notify-hook.sh did.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notificationsEnabled"
    private var authorized = false
    /// Called with the session id when the user clicks a notification.
    var onActivate: (String) -> Void = { _ in }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { requestAuthorization() }
        }
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        if enabled { requestAuthorization() }
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                if let error { CubiLog.write("notification authorization failed: \(error)") }
            }
        }
    }

    func notify(title: String, body: String, thread: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { CubiLog.write("notification failed: \(error)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Cubi is a menubar app: its banners must show even while it is "active".
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let thread = response.notification.request.content.threadIdentifier
        Task { @MainActor in
            CubiLog.write("notification clicked: session=\(thread.prefix(8))")
            self.onActivate(thread)
            completionHandler()
        }
    }
}
