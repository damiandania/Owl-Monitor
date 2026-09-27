import Foundation

/// What a notification is about — the user toggles these per-category in Settings.
enum NotificationCategory: String, Codable, Sendable, CaseIterable {
    case failures   // crash, gave up, OOM auto-retry
    case recovery   // recycled, revived, recovered
    case builds     // build success / failure
    case pressure   // machine stuck, orphans auto-closed, pressure recovered
}

/// Urgency: drives sound + interruption level. Urgent cuts through Focus; passive is silent.
enum NotificationSeverity: Sendable { case urgent, passive }

/// Which set of interactive buttons (UNNotificationCategory) to attach.
enum NotificationAction: String, Sendable {
    case none           // no buttons
    case restartOpen    // crash / failed → "Restart" + "Open"
    case openLogs       // build failed   → "Open logs"
    case open           // pressure       → "Open"
    case freeMemory     // low memory at launch → "Stop Other Servers" + "Open"

    /// The registered `UNNotificationCategory` identifier (nil = no buttons).
    var categoryIdentifier: String? {
        switch self {
        case .none:        return nil
        case .restartOpen: return "RESTART_OPEN"
        case .openLogs:    return "OPEN_LOGS"
        case .open:        return "OPEN"
        case .freeMemory:  return "FREE_MEMORY"
        }
    }
}

/// One notification: the unit shown both as a system banner and in the in-app feed.
struct NotificationItem: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let body: String
    let category: NotificationCategory
    let severity: NotificationSeverity
    let projectID: UUID?    // Project.ID; nil for machine-wide events (pressure). Drives grouping + actions.
    let action: NotificationAction

    init(title: String, body: String, category: NotificationCategory,
         severity: NotificationSeverity, projectID: UUID?, action: NotificationAction,
         id: UUID = UUID(), date: Date = Date()) {
        self.id = id; self.date = date
        self.title = title; self.body = body
        self.category = category; self.severity = severity
        self.projectID = projectID; self.action = action
    }
}

/// Static catalog for the Settings UI (mirrors `AppSettings.allBars`). `id` drives `ForEach`.
enum NotificationCatalog {
    static let all: [(id: NotificationCategory, label: String, systemImage: String)] = [
        (.failures, "Failures (crash, gave up, OOM retry)", "xmark.octagon"),
        (.recovery, "Recovery (recycled, revived, recovered)", "arrow.clockwise"),
        (.builds,   "Builds (success / failure)", "hammer"),
        (.pressure, "System pressure (stuck, orphans, recovered)", "gauge.with.dots.needle.67percent"),
    ]
}
