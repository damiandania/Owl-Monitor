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

let table = """
You are currently using your subscription to power your Claude Code usage

Current session: 16% used · resets Oct 2 at 8pm (Europe/Paris)
Current week (all models): 86% used · resets Oct 4 at 10pm (Europe/Paris)
"""
let hookError = "SessionEnd hook [node \"${CLAUDE_PLUGIN_ROOT}/hooks/session-end-cleanup.mjs\"] failed: /bin/sh: node: command not found"

chk(M.classify(out: table, err: "", code: 0) == .data(five: 16, seven: 86), "usage table → both percentages")
chk(M.classify(out: table + "\n" + hookError, err: "", code: 0) == .data(five: 16, seven: 86),
    "usage table + a failing hook's 'command not found' → still the numbers")
chk(M.classify(out: table, err: hookError, code: 0) == .data(five: 16, seven: 86), "…also when the hook error is on stderr")
chk(M.classify(out: "Current session: 7% used", err: "", code: 0) == .data(five: 7, seven: nil), "one window only → partial data")

chk(M.classify(out: "", err: "zsh:1: command not found: claude", code: 127) == .failure(.notInstalled), "claude missing (127)")
chk(M.classify(out: "", err: "zsh:1: command not found: claude", code: 1) == .failure(.notInstalled), "claude missing, any exit code")
chk(M.classify(out: "", err: "sh: claude: command not found", code: 1) == .failure(.notInstalled), "claude missing (sh spelling)")
chk(M.classify(out: "", err: "", code: 127) == .failure(.notInstalled), "exit 127 alone → not installed")
chk(M.classify(out: hookError, err: "", code: 0) == .failure(.unavailable),
    "only a hook's 'node: command not found' → NOT 'not installed' (no data, retry)")

chk(M.classify(out: "", err: "Error: not logged in. Please run /login", code: 1) == .failure(.signedOut), "expired login")
chk(M.classify(out: "", err: "", code: 0) == .failure(.unavailable), "empty output → unavailable (retry)")

print(fail == 0 ? "ALL QUOTA TESTS PASSED" : "\(fail) QUOTA TEST(S) FAILED")
exit(Int32(fail))
