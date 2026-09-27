import Foundation
import UserNotifications

/// Posts native macOS notifications for supervision/pressure events. The ONLY type that touches
/// `UNUserNotificationCenter`; every call is wrapped in `dm_try { }` (an ObjC @try/@catch shim) so a
/// notification-subsystem failure can never abort the app — critically, a managed server crashing
/// must not take the supervisor down with it.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private init() {}

    /// Retained delegate (foreground presentation + action routing). Kept alive by this singleton.
    private let delegate = NotificationDelegate()

    /// One-time wiring at launch: set the delegate, register actionable categories, request auth.
    func attach(app: AppState) {
        delegate.app = app
        _ = dm_try {
            let center = UNUserNotificationCenter.current()
            center.delegate = self.delegate
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        registerCategories()
    }

    /// Report whether the user has authorized notifications for the app (drives the Settings prompt
    /// to open System Settings). Guarded; on a daemon failure it simply doesn't call back.
    func authorizationGranted(_ completion: @escaping @MainActor (Bool) -> Void) {
        _ = dm_try {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let granted = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                Task { @MainActor in completion(granted) }
            }
        }
    }

    /// Register the interactive-action sets referenced by `NotificationAction.categoryIdentifier`.
    private func registerCategories() {
        _ = dm_try {
            let restart = UNNotificationAction(identifier: "RESTART", title: "Restart", options: [.foreground])
            let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
            let openLogs = UNNotificationAction(identifier: "OPEN_LOGS", title: "Open logs", options: [.foreground])
            // Background: stopping the other servers needs no window — the banner just goes away.
            let stopOthers = UNNotificationAction(identifier: "STOP_OTHERS", title: "Stop Other Servers", options: [])
            let categories: Set<UNNotificationCategory> = [
                UNNotificationCategory(identifier: "RESTART_OPEN", actions: [restart, open],
                                       intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: "OPEN_LOGS", actions: [openLogs],
                                       intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: "OPEN", actions: [open],
                                       intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: "FREE_MEMORY", actions: [stopOthers, open],
                                       intentIdentifiers: [], options: []),
            ]
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
    }

    /// Post a system banner for an item. Urgent → sound + time-sensitive; passive → silent.
    func post(_ item: NotificationItem) {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        switch item.severity {
        case .urgent:
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        case .passive:
            content.interruptionLevel = .passive
        }
        if let pid = item.projectID { content.threadIdentifier = pid.uuidString }   // group per project
        if let categoryID = item.action.categoryIdentifier { content.categoryIdentifier = categoryID }
        content.userInfo = ["projectID": item.projectID?.uuidString ?? "", "action": item.action.rawValue]
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        deliver(request)
    }

    /// Add a request, guarded so a notification subsystem failure can never abort the app
    /// (critically: a *managed server crashing* must not take the supervisor down with it).
    private func deliver(_ request: UNNotificationRequest) {
        _ = dm_try { UNUserNotificationCenter.current().add(request) }
    }
}
