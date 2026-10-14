import Foundation

// Tests the pure logic behind the toolbar's countdown ring: SleepGuard.remainingFraction.
// The IOKit power-assertion side (enable/disable actually holding/releasing sleep) is exercised
// live, not here — see the scratch harnesses used during development.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let now = Date()

chk(SleepGuard.remainingFraction(activeUntil: nil, totalDuration: nil, now: now) == nil,
    "remainingFraction: inactive (no deadline) → nil")
chk(SleepGuard.remainingFraction(activeUntil: now.addingTimeInterval(900), totalDuration: nil, now: now) == nil,
    "remainingFraction: indefinite (no total duration) → nil")

let justStarted = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(900), totalDuration: 900, now: now)
chk(justStarted.map { abs($0 - 1.0) < 0.001 } ?? false, "remainingFraction: just enabled → ~1.0", "\(String(describing: justStarted))")

let halfway = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(450), totalDuration: 900, now: now)
chk(halfway.map { abs($0 - 0.5) < 0.001 } ?? false, "remainingFraction: halfway → ~0.5", "\(String(describing: halfway))")

let aboutToExpire = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(1), totalDuration: 900, now: now)
chk(aboutToExpire.map { $0 > 0 && $0 < 0.01 } ?? false, "remainingFraction: about to expire → near 0", "\(String(describing: aboutToExpire))")

let expired = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(-5), totalDuration: 900, now: now)
chk(expired == 0, "remainingFraction: past the deadline clamps at 0 (never negative)", "\(String(describing: expired))")

let overdue = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(950), totalDuration: 900, now: now)
chk(overdue == 1, "remainingFraction: re-armed past the original total clamps at 1 (never over)", "\(String(describing: overdue))")


// ── add time / status (the `owl-monitor awake` commands) ──
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
chk(SleepGuard.deadline(afterAdding: 1800, activeUntil: t0.addingTimeInterval(600), now: t0) == t0.addingTimeInterval(2400),
    "awake: adding 30 min to a 10 min deadline → 40 min from now")
chk(SleepGuard.deadline(afterAdding: 1800, activeUntil: nil, now: t0) == t0.addingTimeInterval(1800), "awake: no deadline → counts from now")
chk(SleepGuard.deadline(afterAdding: 1800, activeUntil: t0.addingTimeInterval(-60), now: t0) == t0.addingTimeInterval(1800),
    "awake: an already-expired deadline counts from now, not from the past")
let off = SleepGuard.snapshot(isActive: false, activeUntil: nil, now: t0)
chk(off == .init(active: false, indefinite: false, until: nil, remainingSeconds: nil) && off.text == "Keep awake: off", "awake: off snapshot")
let timed = SleepGuard.snapshot(isActive: true, activeUntil: t0.addingTimeInterval(1234.2), now: t0)
chk(timed.active && !timed.indefinite && timed.remainingSeconds == 1235, "awake: remaining rounds up to whole seconds", "\(timed.remainingSeconds ?? -1)")
chk(SleepGuard.snapshot(isActive: true, activeUntil: t0.addingTimeInterval(-5), now: t0).remainingSeconds == 0, "awake: never negative")
let forever = SleepGuard.snapshot(isActive: true, activeUntil: nil, now: t0)
chk(forever.active && forever.indefinite && forever.until == nil && forever.text.contains("indefinitely"), "awake: indefinite snapshot")
let j = (try? JSONSerialization.jsonObject(with: Data(timed.json.utf8))) as? [String: Any] ?? [:]
chk(j["active"] as? Bool == true && j["indefinite"] as? Bool == false && j["remainingSeconds"] as? Int == 1235
    && j["until"] as? String == ISO8601DateFormatter().string(from: t0.addingTimeInterval(1234.2)), "awake: JSON has active/until/remainingSeconds", timed.json)
let jo = (try? JSONSerialization.jsonObject(with: Data(off.json.utf8))) as? [String: Any] ?? [:]
chk(jo["active"] as? Bool == false && jo["until"] is NSNull && jo["remainingSeconds"] is NSNull, "awake: off JSON has nulls")

print(fail == 0 ? "ALL SLEEPGUARD TESTS PASSED" : "\(fail) SLEEPGUARD TEST(S) FAILED")
exit(Int32(fail))
