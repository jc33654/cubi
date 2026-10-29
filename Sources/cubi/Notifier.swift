import Foundation
import UserNotifications

/// System notifications from Cubi. Off by default: the user's own Notification hook already
/// notifies, so this stays quiet until they switch over.
@MainActor
final class Notifier {
    static let enabledKey = "notificationsEnabled"
    private var authorized = false

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { requestAuthorization() }
        }
    }

    init() {
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
}
