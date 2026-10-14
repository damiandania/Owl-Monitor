import Foundation

// Tests how `claude -p '/usage'` output is turned into a notch readout. The regression: a Claude Code
// HOOK that fails (`sh: node: command not found`, since the app's PATH has no node) prints into the
// same output as a perfectly good usage table, and the monitor read it as "claude isn't installed" —
// a `?` badge next to a valid reading.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}
typealias M = ClaudeQuotaMonitor

/// The two percentages of a `.data` result, ignoring the reset times (covered separately below).
func nums(_ r: M.ProbeResult) -> [Int?]? {
    if case .data(let five, let seven, _) = r { return [five, seven] }
    return nil
}

let table = """
You are currently using your subscription to power your Claude Code usage

Current session: 16% used · resets Oct 2 at 8pm (Europe/Paris)
Current week (all models): 86% used · resets Oct 4 at 10pm (Europe/Paris)
"""
let hookError = "SessionEnd hook [node \"${CLAUDE_PLUGIN_ROOT}/hooks/session-end-cleanup.mjs\"] failed: /bin/sh: node: command not found"

chk(nums(M.classify(out: table, err: "", code: 0)) == [16, 86], "usage table → both percentages")
chk(nums(M.classify(out: table + "\n" + hookError, err: "", code: 0)) == [16, 86],
    "usage table + a failing hook's 'command not found' → still the numbers")
chk(nums(M.classify(out: table, err: hookError, code: 0)) == [16, 86], "…also when the hook error is on stderr")
chk(nums(M.classify(out: "Current session: 7% used", err: "", code: 0)) == [7, nil], "one window only → partial data")

chk(M.classify(out: "", err: "zsh:1: command not found: claude", code: 127) == .failure(.notInstalled), "claude missing (127)")
chk(M.classify(out: "", err: "zsh:1: command not found: claude", code: 1) == .failure(.notInstalled), "claude missing, any exit code")
chk(M.classify(out: "", err: "sh: claude: command not found", code: 1) == .failure(.notInstalled), "claude missing (sh spelling)")
chk(M.classify(out: "", err: "", code: 127) == .failure(.notInstalled), "exit 127 alone → not installed")
chk(M.classify(out: hookError, err: "", code: 0) == .failure(.unavailable),
    "only a hook's 'node: command not found' → NOT 'not installed' (no data, retry)")

chk(M.classify(out: "", err: "Error: not logged in. Please run /login", code: 1) == .failure(.signedOut), "expired login")
chk(M.classify(out: "", err: "", code: 0) == .failure(.unavailable), "empty output → unavailable (retry)")

// ── reset times, parsed from the `/usage` text ──
var cal = Calendar(identifier: .gregorian)
let paris = TimeZone(identifier: "Europe/Paris")!
cal.timeZone = paris
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
let now = at(2026, 10, 2, 15, 0)   // Fri 2 Oct 2026, 15:00 Paris
func reset(_ line: String) -> Date? { M.parseReset(after: "Current session:", in: line, now: now) }
chk(reset("Current session: 16% used · resets Oct 2 at 8pm (Europe/Paris)") == at(2026, 10, 2, 20), "reset: 'Oct 2 at 8pm' in the named zone")
chk(reset("Current session: 16% used · resets Oct 4 at 10:30pm (Europe/Paris)") == at(2026, 10, 4, 22, 30), "reset: minutes and pm")
chk(reset("Current session: 5% used · resets Oct 3 at 12am (Europe/Paris)") == at(2026, 10, 3, 0), "reset: 12am is midnight")
chk(reset("Current session: 5% used · resets Oct 3 at 12pm (Europe/Paris)") == at(2026, 10, 3, 12), "reset: 12pm is noon")
chk(reset("Current session: 5% used · resets 8pm (Europe/Paris)") == at(2026, 10, 2, 20), "reset: bare time later today")
chk(reset("Current session: 5% used · resets 9am (Europe/Paris)") == at(2026, 10, 3, 9), "reset: bare time already past → tomorrow")
chk(reset("Current session: 5% used · resets Jan 5 at 9am (Europe/Paris)") == at(2027, 1, 5, 9), "reset: a date earlier in the year → next year")
chk(M.parseReset(after: "Current session:", in: "Current session: 5% used · resets 8pm (Europe/London)", now: now)
        == { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!
             return c.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 20))! }(), "reset: honours the zone it is given")
chk(reset("Current session: 16% used") == nil, "reset: line without one → nil")
chk(reset("Current session: 16% used · resets soonish (Europe/Paris)") == nil, "reset: garbage → nil, not a crash")
chk(M.parseReset(after: "Current week (all models):", in: table + "\nCurrent week (all models): 86% used · resets Oct 4 at 10pm (Europe/Paris)", now: now) == at(2026, 10, 4, 22),
    "reset: the label selects its own line")
if case .data(_, _, let r) = M.classify(out: table, err: "", code: 0) {
    chk(r.five != nil && r.seven != nil, "classify: carries both reset times alongside the percentages")
} else { chk(false, "classify: carries both reset times") }

// ── QuotaReport: JSON for another program, and one line each for a human ──
typealias W = QuotaReport.Window
typealias P = QuotaReport.Provider
let reset5 = at(2026, 10, 2, 20), resetW = at(2026, 10, 4, 22)
let okClaude = P(status: .ok, stale: false, updatedAt: now,
                 session: W(usedPercent: 16, resetsAt: reset5, windowMinutes: 300),
                 weekly: W(usedPercent: 86, resetsAt: resetW, windowMinutes: 10080))
let thirtyDay = W(usedPercent: 39, resetsAt: resetW, windowMinutes: 43200)
let freeCodex = P(status: .ok, stale: false, updatedAt: now, session: nil, weekly: nil, other: [thirtyDay])
func parsed(_ json: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:] }
let report = parsed(QuotaReport.json(claude: okClaude, codex: freeCodex))
let cl = report["claude"] as? [String: Any] ?? [:]
let cs = cl["session"] as? [String: Any] ?? [:]
chk(cl["status"] as? String == "ok" && cl["error"] is NSNull && cl["stale"] as? Bool == false, "report: healthy provider → status ok, error null")
chk(cs["percentLeft"] as? Int == 84 && cs["percentUsed"] as? Int == 16 && cs["windowMinutes"] as? Int == 300, "report: session left/used/minutes")
chk(cs["resetsAt"] as? String == ISO8601DateFormatter().string(from: reset5), "report: resetsAt is ISO 8601 (UTC)", "\(cs["resetsAt"] ?? "nil")")
chk((cl["weekly"] as? [String: Any])?["percentLeft"] as? Int == 14, "report: weekly percentLeft")
let cx = report["codex"] as? [String: Any] ?? [:]
chk(cx["session"] is NSNull && cx["weekly"] is NSNull && (cx["other"] as? [Any])?.count == 1, "report: a 30-day Codex window is listed under 'other', not mislabelled")
chk(((cx["other"] as? [[String: Any]])?.first)?["windowMinutes"] as? Int == 43200, "report: …with its real window length")
let down = parsed(QuotaReport.json(claude: P(status: .signedOut, stale: true, updatedAt: now, session: W(usedPercent: 5, resetsAt: nil, windowMinutes: 300), weekly: nil),
                                  codex: P(status: .notInstalled, stale: true, updatedAt: nil, session: nil, weekly: nil)))
let dc = down["claude"] as? [String: Any] ?? [:]
chk(dc["status"] as? String == "signedOut" && dc["error"] as? String == "signedOut" && dc["session"] is NSNull,
    "report: a failed provider reports the error and hides its last-known numbers")
chk((down["codex"] as? [String: Any])?["error"] as? String == "notInstalled", "report: Codex not installed → error")
let pending = parsed(QuotaReport.json(claude: okClaude, codex: P(status: .ok, stale: true, updatedAt: nil, session: nil, weekly: nil)))
chk((pending["codex"] as? [String: Any])?["status"] as? String == "pending" && (pending["codex"] as? [String: Any])?["error"] is NSNull,
    "report: no reading yet → pending, not an error")
chk(QuotaReport.classify([W(usedPercent: 10, resetsAt: nil, windowMinutes: 300), W(usedPercent: 20, resetsAt: nil, windowMinutes: 10080)]).weekly?.usedPercent == 20,
    "classify: 5 h → session, 7 d → weekly")
chk(P(status: .ok, stale: false, updatedAt: now, session: W(usedPercent: 120, resetsAt: nil, windowMinutes: 300), weekly: nil) == P(status: .ok, stale: false, updatedAt: now, session: W(usedPercent: 120, resetsAt: nil, windowMinutes: 300), weekly: nil)
    && ((parsed(QuotaReport.json(claude: P(status: .ok, stale: false, updatedAt: now, session: W(usedPercent: 120, resetsAt: nil, windowMinutes: 300), weekly: nil), codex: freeCodex))["claude"] as? [String: Any])?["session"] as? [String: Any])?["percentLeft"] as? Int == 0,
    "report: percentLeft is clamped to 0...100")
chk(report["shown"] as? String == "claude", "report: the notch's provider is in the root, default claude")
chk(parsed(QuotaReport.json(claude: okClaude, codex: freeCodex, shown: "codex"))["shown"] as? String == "codex", "report: shown reflects codex")
chk(QuotaReport.text(claude: okClaude, codex: freeCodex, shown: "codex", now: now).hasSuffix("Notch shows: Codex"), "report: human text says what the notch shows")
let line = QuotaReport.text(claude: okClaude, codex: freeCodex, now: now)
chk(line.contains("5h 84% left") && line.contains("week 14% left") && line.contains("30d 61% left"), "report: human text", line)

print(fail == 0 ? "ALL QUOTA TESTS PASSED" : "\(fail) QUOTA TEST(S) FAILED")
exit(Int32(fail))
