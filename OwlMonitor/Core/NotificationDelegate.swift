import UserNotifications

/// Presents banners while the app is foreground and routes notification-action taps to AppState.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var app: AppState?

    /// Show the banner (with sound) even when Owl Monitor is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Handle a tapped action (Restart / Open / Open logs / Stop Other Servers) or the body itself.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Capture only Sendable values before hopping to the main actor.
        let pidString = response.notification.request.content.userInfo["projectID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            let pid = pidString.flatMap(UUID.init(uuidString:))
            switch action {
            case "RESTART":
                self.app?.restartFromNotification(projectID: pid)
            case "STOP_OTHERS":
                self.app?.stopOtherServersFromNotification(projectID: pid)
            case "OPEN_LOGS":
                self.app?.focusFromNotification(projectID: pid, showLogs: true)
            case "OPEN", UNNotificationDefaultActionIdentifier:
                self.app?.focusFromNotification(projectID: pid, showLogs: false)
            default:
                break
            }
        }
        completionHandler()
    }
}
