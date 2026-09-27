import Foundation
import Darwin

/// Small process-control primitives shared by the dev-server supervisor (`DevSession`) and the
/// one-shot build runner (`BuildRunner`), so the two don't reimplement the same POSIX glue.
enum ProcessSupport {

    /// Decode a `waitpid` status into an exit code, the way both runners need it: a normal exit
    /// (`WIFEXITED`) yields its `WEXITSTATUS`; a signal-terminated process yields the raw status
    /// (a non-zero value that callers treat as "failed"). Replaces the duplicated bit-twiddling.
    static func decodeExitCode(_ status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : status
    }

    /// SIGTERM the whole tree of session leader `leader` — its session members AND any `setsid`
    /// descendants (which escape a plain `killpg`) — then SIGKILL after a short grace so a tree that
    /// ignores the polite signal is still reaped. Fire-and-forget; the escalation runs on a detached
    /// task and re-enumerates so a child spawned during the grace is still caught. Replaces the old
    /// killpg-only path so a detached worker can't outlive the server/build that started it.
    static func gracefulKillTree(_ leader: pid_t, after grace: Duration = .seconds(2)) {
        signalTree(ProcessTree.fullTree(of: leader), SIGTERM)
        Task.detached {
            try? await Task.sleep(for: grace)
            signalTree(ProcessTree.fullTree(of: leader), SIGKILL)
        }
    }

    /// Send `sig` to every pid in `pids` and to each one's process group (so a new group created by a
    /// `setsid` child is reaped too). Pids ≤ 1 are skipped. Shared by the tree-kill and app shutdown.
    static func signalTree(_ pids: [pid_t], _ sig: Int32) {
        for p in Set(pids) where p > 1 {
            kill(p, sig)
            let pg = getpgid(p)
            if pg > 1 { killpg(pg, sig) }
        }
    }

    /// The Node heap flag (`--max-old-space-size=<MB>`) injected via `NODE_OPTIONS`. Centralizes the
    /// GB→MB conversion both runners use; only `NODE_OPTIONS`-allowlisted flags work here (V8 flags
    /// like `--optimize-for-size` are rejected and make node exit immediately).
    static func nodeHeapFlag(memoryGB: Int) -> String {
        "--max-old-space-size=\(memoryGB * 1024)"
    }

    /// Inline shell assignments — `KEY='value' KEY2='value2' ` (trailing space when non-empty) — for
    /// a project's user-defined env vars, prepended ahead of the app's own env (NODE_OPTIONS / PORT /
    /// FORCE_COLOR) when launching through `zsh -lc`. Values are single-quoted with embedded single
    /// quotes escaped (`'\''`), so spaces, `$`, and quotes pass through literally. Placed FIRST so the
    /// app's operational vars still win on a key clash (the heap injection can't be broken by a stray
    /// user NODE_OPTIONS).
    ///
    /// Keys are NOT quoted — a shell assignment's name can't be — so they're the injection surface:
    /// only a valid POSIX name (see `isValidEnvKey`) is emitted, and anything else is dropped rather
    /// than spliced into the command `zsh` executes. `redacted` swaps every value for `•••` — use it
    /// for anything displayed or written to a log (see `displayCommand`).
    static func envAssignments(_ env: [Project.EnvVar], redacted: Bool = false) -> String {
        let parts = env.compactMap { pair -> String? in
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            guard isValidEnvKey(key) else { return nil }
            if redacted { return "\(key)=•••" }
            let escaped = pair.value.replacingOccurrences(of: "'", with: "'\\''")
            return "\(key)='\(escaped)'"
        }
        return parts.isEmpty ? "" : parts.joined(separator: " ") + " "
    }

    /// A POSIX environment-variable name: a letter or `_`, then letters, digits or `_`. Anything else
    /// — spaces, `;`, `$(…)`, `=`, a leading digit — would either break the launch or be executed by
    /// the shell, since the key is the one part of an assignment that can't be quoted. Pure.
    static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return key.unicodeScalars.allSatisfy {
            $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
    }

    /// The `$ <command>  (cwd: …)` header a runner logs before launching, with the project's env
    /// values REDACTED. The runners used to log the real command, which put every env value — API
    /// keys, database URLs, tokens — in plaintext into the on-disk log, the in-app terminal, and
    /// `owl-monitor logs` (which coding agents are told to read). `userEnv` is the one piece that can
    /// hold secrets, so it's the one swapped; the operational vars (heap, PORT) stay visible because
    /// they're what you need when debugging a launch.
    static func displayCommand(env: [Project.EnvVar], rest: String, cwd: String) -> String {
        "$ \(envAssignments(env, redacted: true))\(rest)  (cwd: \(cwd))"
    }
}
