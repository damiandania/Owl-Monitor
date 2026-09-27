import Foundation
import Observation

/// Why a quota readout can't show numbers. Each case maps to a DISTINCT notch badge + tooltip, so a
/// blank readout tells the user what to DO (re-auth, install, or just wait) instead of silently
/// freezing on a stale — and misleadingly low — percentage. Shared by the Claude and Codex monitors.
enum QuotaStatus: Equatable {
    case ok             // numbers are current
    case notInstalled   // the CLI isn't on PATH
    case signedOut      // installed, but the login/OAuth session expired or is missing
    case unavailable    // ran but returned no readable data (contention / unknown) — worth retrying
}

/// Claude subscription usage for the notch HUD. `claude -p "/usage"` is the one reliable
/// local source: the statusline only carries `rate_limits` while an interactive session happens to be
/// rendering it (not guaranteed, and absent in IDE/SDK contexts). We run it off-main on a slow cadence
/// and parse the two headline percentages — the rolling 5-hour window ("Current session") and the
/// 7-day window ("Current week (all models)").
@MainActor
@Observable
final class ClaudeQuotaMonitor {
    private(set) var fiveHour: Int?
    private(set) var sevenDay: Int?
    private(set) var updatedAt: Date?
    /// Health of the most recent probe (after its retries). Drives which badge the HUD shows; while
    /// it isn't `.ok` the HUD hides the last-known numbers rather than let a frozen reading look like
    /// a fresh, reassuring one. Starts `.ok` so the readout is simply BARE until the first probe
    /// lands (no error flash on launch).
    private(set) var status: QuotaStatus = .ok

    /// Refreshed every ~15 min while healthy; treat a reading older than 20 min as stale (belt and
    /// braces alongside `status` — e.g. if the timer itself somehow stopped firing).
    var isStale: Bool {
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 20 * 60
    }

    /// True once we've ever parsed a reading — lets the HUD stay bare until the first result lands.
    var hasData: Bool { fiveHour != nil || sevenDay != nil }

    private var timer: Timer?
    /// Cadence once healthy; a shorter one while the status isn't `.ok`, so a transient failure
    /// (heavy concurrent Claude Code usage, or a login the user just refreshed) clears within a
    /// couple of minutes instead of sitting on the badge for up to 15 min.
    private static let healthyInterval: TimeInterval = 15 * 60
    private static let retryInterval: TimeInterval = 2 * 60

    init() {
        refresh()
        scheduleTimer(interval: Self.healthyInterval)
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        // Each poll spawns a `claude` process (a few seconds), so keep the cadence slow — the 5h/7d
        // windows move slowly, so ~15-min granularity is plenty once readings are coming through.
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Fetch (with retries + a diagnostic) off the main actor, then publish on it.
    func refresh() {
        Task.detached(priority: .utility) {
            let result = await Self.probe()
            await MainActor.run {
                switch result {
                case .data(let five, let seven):
                    if let five { self.fiveHour = five }
                    if let seven { self.sevenDay = seven }
                    self.updatedAt = Date()
                    self.apply(.ok)
                case .failure(let status):
                    self.apply(status)
                }
            }
        }
    }

    /// Publish a new status and, when the health flips, re-arm the timer at the matching cadence.
    private func apply(_ newStatus: QuotaStatus) {
        let wasHealthy = status == .ok
        status = newStatus
        let nowHealthy = newStatus == .ok
        if nowHealthy != wasHealthy {
            scheduleTimer(interval: nowHealthy ? Self.healthyInterval : Self.retryInterval)
        }
    }

    private enum ProbeResult { case data(five: Int?, seven: Int?), failure(QuotaStatus) }

    /// Primary probe (`claude -p '/usage'`, up to 3 attempts) for the numbers, plus a one-shot
    /// `claude usage` diagnostic to explain a persistent hollow response. `-p '/usage'` SWALLOWS the
    /// real cause of a failure (it exits 0 printing an empty cost summary even when the OAuth session
    /// has expired); the dedicated `claude usage` subcommand surfaces that on a non-zero exit, which
    /// is the only way to tell "signed out" apart from transient contention.
    nonisolated private static func probe() async -> ProbeResult {
        let delaysNs: [UInt64] = [0, 4_000_000_000, 10_000_000_000]
        var last: ProbeResult = .failure(.unavailable)
        for (i, delay) in delaysNs.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let r = run("claude -p '/usage' --strict-mcp-config") else { continue }
            let result = classify(out: r.out, err: r.err, code: r.code)
            switch result {
            case .data:                     return result            // got the numbers
            case .failure(.notInstalled):   return result            // no point retrying a missing CLI
            case .failure(.signedOut):      return result            // definitive — surface it now
            case .failure:                  last = result            // hollow/unknown — retry
            }
            _ = i
        }
        // Every primary attempt came back hollow. Ask the dedicated subcommand WHY — it reveals an
        // expired login that `-p '/usage'` hid, and (if auth is actually fine) may even return the
        // numbers, in which case the hollow runs were just contention.
        if let d = run("claude usage") {
            let diag = classify(out: d.out, err: d.err, code: d.code)
            switch diag {
            case .data:                                     return diag
            case .failure(let s) where s != .unavailable:   return .failure(s)
            default:                                        break
            }
        }
        return last
    }

    /// Turn one probe's stdout/stderr/exit code into a result: parsed numbers, or a classified
    /// failure. Ordering matters — a missing CLI and an auth error are checked before "hollow".
    nonisolated private static func classify(out: String, err: String, code: Int32) -> ProbeResult {
        let blob = (out + "\n" + err).lowercased()
        if code == 127 || blob.contains("command not found") { return .failure(.notInstalled) }
        let five = percent(after: "Current session:", in: out)
        let seven = percent(after: "Current week (all models):", in: out)
        if five != nil || seven != nil { return .data(five: five, seven: seven) }
        if looksSignedOut(blob) { return .failure(.signedOut) }
        return .failure(.unavailable)   // ran, exited, but produced nothing usable
    }

    /// Auth-failure signatures, kept specific to avoid a false positive from a login-shell banner
    /// (e.g. a "Last login:" line) — no bare "login"/"log in" match.
    nonisolated private static func looksSignedOut(_ lowerBlob: String) -> Bool {
        let markers = ["authenticat", "oauth", "not logged in", "session expired",
                       "please log in", "please login", "/login", "sign in", "unauthorized"]
        return markers.contains { lowerBlob.contains($0) }
    }

    /// Run a command through a login shell (so `claude` resolves on PATH, as ClaudeRunner does) and
    /// return its stdout, stderr and exit code. Blocking — only call off the main actor.
    ///
    /// Kept deliberately low-footprint, because this child is launched by Owl Monitor and macOS
    /// attributes anything it touches back to Owl Monitor (TCC prompts for Downloads/Music/Desktop/…):
    ///   • runs in an EMPTY cwd — claude treats its cwd as the project, and the app's inherited cwd is
    ///     `/`, so it would walk down into the protected `~/Desktop`, `~/Documents`, `~/Downloads`, …;
    ///     an empty scratch dir gives it nothing to scan.
    ///   • stdin is `/dev/null` so claude doesn't stall ~3s waiting for piped input.
    /// Outputs are tiny (a usage table or a one-line error), so reading stdout fully then stderr
    /// can't deadlock the pipe buffers.
    nonisolated private static func run(_ command: String) -> (out: String, err: String, code: Int32)? {
        let probeDir = FileManager.default.temporaryDirectory.appendingPathComponent("dm-quota-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = probeDir
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                process.terminationStatus)
    }

    /// The integer just before the first `%` following `label` — e.g. `label` "Current session:" in
    /// "Current session: 5% used" yields 5.
    nonisolated private static func percent(after label: String, in text: String) -> Int? {
        guard let start = text.range(of: label) else { return nil }
        var digits = ""
        for ch in text[start.upperBound...] {
            if ch.isNumber { digits.append(ch) }
            else if ch == "%" { return Int(digits) }
            else if !digits.isEmpty { return nil }   // a non-digit split the number off from its %
        }
        return nil
    }
}

/// Codex / GPT subscription usage for the notch HUD. The locally installed Codex app-server exposes
/// the signed-in account's rate-limit snapshot through `account/rateLimits/read`; using it keeps the
/// HUD read-only and avoids inspecting credentials or calling undocumented web endpoints.
@MainActor
@Observable
final class CodexQuotaMonitor {
    struct Window: Equatable {
        let usedPercent: Int
        let durationMinutes: Int?
    }

    private(set) var primary: Window?
    private(set) var secondary: Window?
    private(set) var updatedAt: Date?
    /// Same classified health as the Claude monitor, so the HUD can tell "Codex isn't installed"
    /// apart from "installed but signed out" apart from "couldn't read it" — instead of one blank `—`.
    /// Starts `.ok` so the readout is bare until the first probe lands.
    private(set) var status: QuotaStatus = .ok

    var isStale: Bool {
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 15 * 60
    }

    var hasData: Bool { primary != nil || secondary != nil }

    private var timer: Timer?
    private static let healthyInterval: TimeInterval = 10 * 60
    private static let retryInterval: TimeInterval = 2 * 60

    /// Starts the on-demand monitor (called when the user switches the notch to GPT) and immediately
    /// obtains a fresh value, so the first click never waits for a background polling interval.
    func activate() {
        refresh()
        guard timer == nil else { return }
        scheduleTimer(interval: Self.healthyInterval)
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let result = Self.fetchRateLimits()
            await MainActor.run {
                switch result {
                case .data(let primary, let secondary):
                    self.primary = primary
                    self.secondary = secondary
                    self.updatedAt = Date()
                    self.apply(.ok)
                case .failure(let status):
                    self.apply(status)
                }
            }
        }
    }

    private func apply(_ newStatus: QuotaStatus) {
        let wasHealthy = status == .ok
        status = newStatus
        let nowHealthy = newStatus == .ok
        // Only re-arm once the monitor is actually running (activate() started it); before that the
        // timer is nil and the next activate() schedules it.
        if timer != nil, nowHealthy != wasHealthy {
            scheduleTimer(interval: nowHealthy ? Self.healthyInterval : Self.retryInterval)
        }
    }

    private enum ProbeResult { case data(primary: Window?, secondary: Window?), failure(QuotaStatus) }

    /// Requests a short-lived JSON-RPC snapshot from the installed Codex CLI. Its initialization is
    /// asynchronous: closing stdin immediately after sending `initialized` causes Codex to discard
    /// the following request. Space the handshake messages and keep stdin open briefly for the reply;
    /// the helper then exits, so Owl Monitor never owns a long-lived Codex process. Blocking — keep
    /// this off the main actor. Classifies a failure (missing CLI / signed out / unreadable) so the
    /// HUD can guide the user instead of just blanking.
    nonisolated private static func fetchRateLimits() -> ProbeResult {
        guard let executable = codexExecutable() else { return .failure(.notInstalled) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A GUI app launched by macOS does not inherit the terminal's PATH, where `codex` was
        // available during development. Resolve the bundled executable first rather than relying on
        // a login shell to discover it.
        process.arguments = ["-c", """
            { printf '%s\\n' '{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"Owl Monitor\",\"version\":\"1.0\"}}}'; sleep 0.2; \
              printf '%s\\n' '{\"method\":\"initialized\"}'; sleep 0.2; \
              printf '%s\\n' '{\"id\":2,\"method\":\"account/rateLimits/read\"}'; sleep 2; } | exec \(shellQuote(executable)) app-server --stdio
            """]

        let output = Pipe(), errPipe = Pipe()
        process.standardOutput = output
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return .failure(.notInstalled) }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let blob = (text + "\n" + String(decoding: errData, as: UTF8.self)).lowercased()

        // Missing CLI: `command not found` (exit 127) — the most common "nothing shows" cause.
        if process.terminationStatus == 127 || blob.contains("command not found") {
            return .failure(.notInstalled)
        }

        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let response = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (response["id"] as? Int) == 2,
                  let result = response["result"] as? [String: Any],
                  let limits = codexLimits(in: result) else { continue }
            return .data(primary: window(in: limits, key: "primary"),
                         secondary: window(in: limits, key: "secondary"))
        }
        // Installed but no rate-limit snapshot came back: distinguish a signed-out account (the
        // app-server answers the read with an auth error) from an otherwise-empty/unknown reply.
        if looksSignedOut(blob) { return .failure(.signedOut) }
        return .failure(.unavailable)
    }

    /// Codex Desktop currently bundles its CLI in ChatGPT.app; retain the standalone app and usual
    /// user-local locations as fallbacks. All are checked directly because a LaunchServices app has
    /// only macOS's minimal PATH.
    nonisolated private static func codexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    nonisolated private static func looksSignedOut(_ lowerBlob: String) -> Bool {
        let markers = ["not logged in", "not authenticated", "unauthorized", "authenticat",
                       "sign in", "please log in", "please login", "codex login", "no credentials"]
        return markers.contains { lowerBlob.contains($0) }
    }

    /// Recent Codex versions expose a per-product dictionary; older versions return the same Codex
    /// bucket directly as `rateLimits`. Accept both so updating Codex does not break the HUD.
    nonisolated private static func codexLimits(in result: [String: Any]) -> [String: Any]? {
        if let allLimits = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = allLimits["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    nonisolated private static func window(in limits: [String: Any], key: String) -> Window? {
        guard let raw = limits[key] as? [String: Any],
              let usedPercent = raw["usedPercent"] as? Int else { return nil }
        return Window(usedPercent: usedPercent, durationMinutes: raw["windowDurationMins"] as? Int)
    }
}
