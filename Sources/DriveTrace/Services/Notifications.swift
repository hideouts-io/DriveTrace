import AppKit
import UserNotifications
import DriveCore

final class NotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

func requireNotificationAuthorization(_ status: UNAuthorizationStatus) throws {
    switch status {
    case .authorized, .provisional: return
    case .notDetermined:
        throw MonitorError.invalid("Notification permission has not been requested. Enable Native watch notifications in Settings and respond to the macOS permission prompt. Pending watch records are retained.")
    case .denied:
        throw MonitorError.invalid("macOS has denied notification permission. Open System Settings → Notifications → DriveTrace and allow notifications, then refresh Drive to retry pending watch records.")
    @unknown default:
        throw MonitorError.invalid("macOS returned an unsupported notification authorization state (\(status.rawValue)). Check System Settings → Notifications. Pending watch records are retained.")
    }
}

func notificationStatus(_ settings: UNNotificationSettings) -> String {
    switch settings.authorizationStatus {
    case .notDetermined: return "Permission not requested"
    case .denied: return "Denied in macOS System Settings"
    case .provisional: return "Quiet delivery permitted · banners are not authorized"
    case .authorized:
        return settings.alertSetting == .enabled ? "Allowed · alerts enabled" : "Allowed · alerts disabled in macOS"
    @unknown default: return "Unsupported authorization state (\(settings.authorizationStatus.rawValue))"
    }
}
