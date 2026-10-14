import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping AND from dimming/sleeping its display — the same pair of IOKit
/// power-management assertions `caffeinate -d -i` holds — so a long build or dev session isn't cut
/// off mid-way. Enabled for a fixed duration or indefinitely; session-only (never persisted, so a
/// relaunch always starts back in "allowed to sleep") and released on quit (`AppState.shutdown`) so
/// nothing outlives the app (macOS would also auto-release the assertions if the process died some
/// other way).
@MainActor
@Observable
final class SleepGuard {
    private(set) var isActive = false
    /// When the guard will turn itself off; nil while active means "indefinitely".
    private(set) var activeUntil: Date?
    /// The duration `enable(for:)` was called with — needed alongside `activeUntil` to compute the
    /// toolbar ring's remaining-time FRACTION (a bare deadline alone gives remaining time, not the
    /// proportion of the original duration). nil while active means "indefinitely" (no ring).
    private(set) var totalDuration: TimeInterval?
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var autoOffTask: Task<Void, Never>?

    /// Enable for `duration` seconds, or indefinitely when `duration` is nil. Re-arms cleanly if
    /// already active (e.g. picking a new duration while it's running).
    func enable(for duration: TimeInterval? = nil) {
        disable()
        let reason = "Owl Monitor: keep awake enabled" as CFString
        var sysID: IOPMAssertionID = 0
        var dispID: IOPMAssertionID = 0
        let sysOK = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &sysID) == kIOReturnSuccess
        let dispOK = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &dispID) == kIOReturnSuccess
        guard sysOK || dispOK else { return }   // both failed — nothing held, stay off
        systemAssertionID = sysOK ? sysID : 0
        displayAssertionID = dispOK ? dispID : 0
        isActive = true
        guard let duration else { return }
        totalDuration = duration
        activeUntil = Date().addingTimeInterval(duration)
        scheduleAutoOff(after: duration)
    }

    /// Turn the guard off after `seconds`, replacing any pending auto-off.
    private func scheduleAutoOff(after seconds: TimeInterval) {
        autoOffTask?.cancel()
        autoOffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled else { return }
            self?.disable()
        }
    }

    /// Add `seconds` of keep-awake time. Off → turns on for exactly that long; on with a deadline →
    /// pushes the deadline out; on indefinitely → nothing to add, left as it is. The assertions are
    /// never released and re-taken, so the Mac can't slip into sleep between the two.
    func add(_ seconds: TimeInterval) {
        guard isActive else { enable(for: seconds); return }
        guard let current = activeUntil else { return }   // indefinite
        let now = Date()
        let newUntil = Self.deadline(afterAdding: seconds, activeUntil: current, now: now)
        // `totalDuration` is what the toolbar ring measures the remaining time against; growing it by
        // the same amount keeps the fraction at most 1.
        totalDuration = (totalDuration ?? 0) + seconds
        activeUntil = newUntil
        scheduleAutoOff(after: newUntil.timeIntervalSince(now))
    }

    /// The new deadline after adding `seconds` to a guard that expires at `activeUntil` (an expired or
    /// missing deadline counts from `now`). Pure.
    nonisolated static func deadline(afterAdding seconds: TimeInterval, activeUntil: Date?, now: Date) -> Date {
        max(activeUntil ?? now, now).addingTimeInterval(seconds)
    }

    /// What `owl-monitor awake status` reports.
    struct Snapshot: Equatable {
        let active: Bool
        /// On with no deadline.
        let indefinite: Bool
        let until: Date?
        let remainingSeconds: Int?

        /// `{"active":…,"indefinite":…,"until":"<ISO 8601, UTC>"|null,"remainingSeconds":…|null}`.
        var json: String {
            let iso = ISO8601DateFormatter()
            let object: [String: Any] = [
                "active": active, "indefinite": indefinite,
                "until": until.map { iso.string(from: $0) } ?? NSNull(),
                "remainingSeconds": remainingSeconds ?? NSNull(),
            ]
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }

        var text: String {
            guard active else { return "Keep awake: off" }
            guard let remainingSeconds, let until else { return "Keep awake: on — indefinitely" }
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "Keep awake: on — \(max(1, Int((Double(remainingSeconds) / 60).rounded(.up)))) min left (until \(f.string(from: until)))"
        }
    }

    /// Pure snapshot of a guard's state at `now`.
    nonisolated static func snapshot(isActive: Bool, activeUntil: Date?, now: Date) -> Snapshot {
        guard isActive else { return Snapshot(active: false, indefinite: false, until: nil, remainingSeconds: nil) }
        guard let activeUntil else { return Snapshot(active: true, indefinite: true, until: nil, remainingSeconds: nil) }
        let remaining = max(0, Int(activeUntil.timeIntervalSince(now).rounded(.up)))
        return Snapshot(active: true, indefinite: false, until: activeUntil, remainingSeconds: remaining)
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        Self.snapshot(isActive: isActive, activeUntil: activeUntil, now: now)
    }

    func disable() {
        autoOffTask?.cancel()
        autoOffTask = nil
        guard isActive else { return }
        if systemAssertionID != 0 { IOPMAssertionRelease(systemAssertionID); systemAssertionID = 0 }
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID); displayAssertionID = 0 }
        isActive = false
        activeUntil = nil
        totalDuration = nil
    }

    /// Fraction of the chosen duration still remaining (1 = just started, 0 = about to expire); nil
    /// while inactive or running indefinitely (nothing to show a ring for).
    nonisolated static func remainingFraction(activeUntil: Date?, totalDuration: TimeInterval?, now: Date) -> Double? {
        guard let activeUntil, let totalDuration, totalDuration > 0 else { return nil }
        return max(0, min(1, activeUntil.timeIntervalSince(now) / totalDuration))
    }
}
