import Foundation

/// What `owl-monitor quota` prints: the Claude and Codex subscription windows the notch shows, as JSON
/// (for another program) or one human line each. Pure — the monitors' readings are passed in — so it is
/// unit-tested without a Claude or Codex install.
enum QuotaReport {
    struct Window: Equatable {
        var usedPercent: Int
        var resetsAt: Date?
        var windowMinutes: Int?
    }

    struct Provider: Equatable {
        var status: QuotaStatus
        /// No fresh reading lately (the monitor's own staleness rule).
        var stale: Bool
        var updatedAt: Date?
        /// The ~5-hour rolling window.
        var session: Window?
        /// The 7-day window.
        var weekly: Window?
        /// Any window that is neither (e.g. Codex's 30-day window on a free plan), so nothing is hidden.
        var other: [Window] = []
    }

    /// Sort windows that only carry a duration (Codex) into session / weekly / other: up to a day is the
    /// short rolling window, six to eight days is the weekly one, anything else is `other`.
    static func classify(_ windows: [Window]) -> (session: Window?, weekly: Window?, other: [Window]) {
        var session: Window?, weekly: Window?
        var other: [Window] = []
        for w in windows {
            let m = w.windowMinutes ?? 0
            if m > 0, m <= 24 * 60, session == nil { session = w }
            else if m >= 6 * 24 * 60, m <= 8 * 24 * 60, weekly == nil { weekly = w }
            else { other.append(w) }
        }
        return (session, weekly, other)
    }

    /// The status word clients see: the monitor's `QuotaStatus`, or `pending` while it is `ok` but has
    /// not produced a reading yet (the first probe takes a few seconds).
    static func statusWord(_ p: Provider) -> String {
        switch p.status {
        case .ok: return p.session == nil && p.weekly == nil && p.other.isEmpty ? "pending" : "ok"
        case .notInstalled: return "notInstalled"
        case .signedOut: return "signedOut"
        case .unavailable: return "unavailable"
        }
    }

    private static func object(_ w: Window?, _ iso: ISO8601DateFormatter) -> Any {
        guard let w else { return NSNull() }
        let used = min(100, max(0, w.usedPercent))
        return [
            "percentUsed": used,
            "percentLeft": 100 - used,
            "resetsAt": w.resetsAt.map { iso.string(from: $0) } ?? NSNull(),
            "windowMinutes": w.windowMinutes ?? NSNull(),
        ] as [String: Any]
    }

    private static func object(_ p: Provider, _ iso: ISO8601DateFormatter) -> [String: Any] {
        let word = statusWord(p)
        let failed = word != "ok" && word != "pending"
        return [
            "status": word,
            // A human-readable reason only when the numbers are not usable.
            "error": failed ? word : NSNull(),
            "stale": p.stale,
            "updatedAt": p.updatedAt.map { iso.string(from: $0) } ?? NSNull(),
            // On failure the last-known numbers are hidden, as in the notch: a frozen reading would look fresh.
            "session": failed ? NSNull() : object(p.session, iso),
            "weekly": failed ? NSNull() : object(p.weekly, iso),
            "other": failed ? [] : p.other.map { object($0, iso) },
        ]
    }

    /// `shown` is the provider the notch is showing right now ("claude" or "codex").
    static func json(claude: Provider, codex: Provider, shown: String = "claude") -> String {
        let iso = ISO8601DateFormatter()
        let root: [String: Any] = ["claude": object(claude, iso), "codex": object(codex, iso), "shown": shown]
        let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// One line per provider: `Claude  5h 84% left (resets 20:00) · week 14% left (resets Oct 4 22:00)`.
    static func text(claude: Provider, codex: Provider, shown: String = "claude", now: Date = Date()) -> String {
        [line("Claude", claude, now), line("Codex ", codex, now), "Notch shows: \(shown == "codex" ? "Codex" : "Claude")"]
            .joined(separator: "\n")
    }

    private static func line(_ name: String, _ p: Provider, _ now: Date) -> String {
        let word = statusWord(p)
        guard word == "ok" else { return "\(name)  \(word == "pending" ? "reading…" : word)" }
        func part(_ label: String, _ w: Window?) -> String? {
            guard let w else { return nil }
            let left = 100 - min(100, max(0, w.usedPercent))
            let f = DateFormatter()
            f.dateFormat = w.resetsAt.map { Calendar.current.isDate($0, inSameDayAs: now) } == true ? "HH:mm" : "MMM d HH:mm"
            let reset = w.resetsAt.map { " (resets \(f.string(from: $0)))" } ?? ""
            return "\(label) \(left)% left\(reset)"
        }
        let parts = [part("5h", p.session), part("week", p.weekly)]
            + p.other.map { w in part(w.windowMinutes.map { "\($0 / 1440)d" } ?? "window", w) }
        let shown = parts.compactMap { $0 }.joined(separator: " · ")
        return "\(name)  \(shown.isEmpty ? "no data" : shown)\(p.stale ? "  (stale)" : "")"
    }
}
