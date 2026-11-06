import Foundation
import UserNotifications

/// Asks macOS once for permission to show notifications (architecture 3.7). The runtime posts under the app's
/// identity, so the question is asked by the app, at launch; macOS shows it only while the answer is undecided, and
/// after a refusal Health says "Notifications: off" until the person allows them in System Settings.
enum NotificationPermission {
    static func ask() {
        // A `swift build` binary or a test run has no bundle identity, and UNUserNotificationCenter needs one.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
