import Foundation
import Observation
import Darwin

/// Supervises a single dev-server process tree: launches it via the C session shim,
/// streams its merged stdout/stderr, samples resource metrics, probes its health, and
/// auto-recycles the whole tree (killpg + relaunch) when it hangs.
@MainActor
@Observable
final class DevSession {
    let project: Project
    private(set) var state: SessionState = .idle
    private(set) var logLines: [String] = []
    private(set) var detectedPort: Int?
    private(set) var pid: pid_t = 0
    private(set) var startedAt: Date?
    private(set) var recycleCount = 0
    /// Exit code of the most recent process exit (nil until it has exited at least once).
    private(set) var lastExitCode: Int32?
    /// Human-readable cause of the last failure, with a remedy when known (e.g. an OOM hint), so an
    /// agent can diagnose from `status --json` without reading internal log files. Cleared on health.
    private(set) var lastError: String?

    /// Supervision-event hook (notifications). Set by AppState; nil in headless tests.
    var onEvent: (@MainActor (SupervisionEvent) -> Void)?
    /// Fired when the OOM autoscaler bumps the heap, with the new GB level. AppState persists it to
    /// the project (`autoHeapGB`) so the next launch starts there. Only invoked in AUTO mode.
    var onHeapEscalated: (@MainActor (Int) -> Void)?

    private let maxLogLines = 2000
    private let trimSlack = 200
    private var lineBuffer = LineBuffer()
    private var process: SpawnedProcess?
    private var graceTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private var stopping = false
    private var stdinFD: Int32 = -1
    private var logFile: FileHandle?

    // Metrics sampling (P2)
    private(set) var history: [MetricPoint] = []
    private let maxHistory = 120
    private var sampleTask: Task<Void, Never>?
    private var tick = 0
    /// Cached session-tree membership: enumerating it means a getsid() scan over every pid on the
    /// machine, and the tree churns slowly after launch — so it's refreshed every few ticks
    /// (`treeRefreshTicks`), not per 1 s sample. Dead pids in between just read as invalid stats.
    private var treePids: [pid_t] = []
    private let treeRefreshTicks = 5
    private var prevTreeCPUns: Int64 = 0
    private var prevWall: UInt64 = 0
    private var prevSysTicks: dm_cpu_ticks?

    // Health & recycle (P3)
    private var healthTask: Task<Void, Never>?
    private var strikes = 0
    private var hasBeenHealthy = false
    private var recycling = false
    private var lastMemoryGB = 4
    private let probeInterval: Duration = .seconds(6)
    private let httpTimeout: TimeInterval = 8   // tolerant of a busy server under load
    private let warmHTTPTimeout: TimeInterval = 3   // snappier flip to .running during warm-up
    private let strikeLimit = 2
    /// If nothing answers HTTP within this window after launch, assume the server is up (e.g. an API
    /// with no "/" route). We never recycle during this window — only after it.
    private let warmUpWindow: Duration = .seconds(150)

    // Crash recovery (auto-revive)
    /// Last port the server actually bound to — re-pinned across recycles/restarts so it doesn't
    /// drift (e.g. 3000 → 3001) when relaunched.
    private var lastKnownPort: Int?
    /// Bounded auto-restart after an unexpected crash (budget restored after a stable healthy streak).
    private var crashRestarts = 0
    private let crashRestartLimit = 3
    /// Consecutive healthy probes since the last (re)launch; the crash budget is only restored once
    /// this reaches `stableProbesToReset`, so a flapping server doesn't auto-restart forever.
    private var stableProbes = 0
    private let stableProbesToReset = 3

    /// When set, this command is launched instead of the project's dev command — used to run the
    /// production-build **preview** (`npm run preview` / `next start`) through the same supervisor.
    let commandOverride: String?

    init(project: Project, commandOverride: String? = nil) {
        self.project = project
        self.commandOverride = commandOverride
    }

    var effectivePort: Int? { detectedPort ?? project.port ?? lastKnownPort }

    /// HTTP-confirmed running — the reliable "ready" signal for agents (true only after a successful
    /// health probe, never during warm-up).
    var isReady: Bool { if case .running = state { return true }; return false }

    /// The server's URL once a port is known (detected, configured, or pinned).
    var url: String? { effectivePort.map { "http://localhost:\($0)/" } }

    // MARK: - Launch / stop

    /// `reservedPorts` — ports other supervised sessions (dev servers + previews) are currently using
    /// or about to bind, so an unconfigured project doesn't have to guess-and-collide the way a
    /// framework's own single-step port fallback does. Passed by `AppState` at launch time; internal
    /// auto-restarts/recycles omit it and rely on the OS-level check in `firstFreePort` instead, since
    /// by then any colliding sibling is either already bound (and so visible to that check) or gone.
    func start(memoryGB: Int, reservedPorts: Set<Int> = []) {
        guard !state.isActive else { return }
        state = .launching
        stopping = false
        recycling = false
        strikes = 0
        lastMemoryGB = memoryGB
        logLines.removeAll()
        lineBuffer.reset()
        detectedPort = nil
        startedAt = Date()
        openLogFile()

        // Resolve the user's real PATH (fnm/nvm/Homebrew live in the interactive rc file) and export
        // it into our environment BEFORE spawning, so the non-interactive `zsh -lc` server inherits a
        // PATH that can find node/npm. Without this, a GUI launch from launchd gets the minimal
        // launchd PATH and the server dies with `command not found: npm` (exit 127). Done here (not
        // once at startup) so it covers auto-restarts/recycles too, and so fnm's ephemeral per-shell
        // PATH dir is freshly resolved rather than stale. See ShellEnvironment.
        if ShellEnvironment.applyResolvedPATH() == nil {
            AppLog.shared.event("DevSession: could not resolve the user shell PATH for \(project.name) — using inherited PATH")
        }

        let baseCommand = commandOverride ?? project.devCommand ?? Detector.detect(path: project.path).devCommand
        // Prepend env inline (the login shell applies it), and `exec` so the dev process
        // REPLACES the shell — making it the session leader we spawned, so the whole tree
        // is reliably enumerable (by session) and killable (by killpg).
        // Pin the port: an explicit project.port always wins, even if it collides — that's a
        // deliberate override. Otherwise reuse the last port the server actually bound to, so a
        // relaunch/recycle keeps the same port instead of drifting (3000→3001) — but only while it's
        // still actually free; a sibling project (in `reservedPorts`) or some unrelated process (the
        // OS-level check) may have since claimed it. Falling back to the framework's own bare `PORT`-
        // less fallback is how two unconfigured projects both land on the same port in the first place
        // (each only knows to dodge ITS OWN default, not what else Owl Monitor is running) — so an
        // unconfigured project always gets a concrete, verified-free port instead.
        let pinnedPort: Int
        if let explicit = project.port {
            pinnedPort = explicit
        } else if let last = lastKnownPort, !reservedPorts.contains(last), !Self.isPortInUse(last) {
            pinnedPort = last
        } else {
            pinnedPort = Self.firstFreePort(from: 3000, avoiding: reservedPorts)
        }
        let portEnv = "PORT=\(pinnedPort) "
        // Record the choice NOW, not only once the server prints its URL. A sibling launched a moment
        // later builds its `reservedPorts` from our `effectivePort`, which for a still-booting server
        // was nil — so two projects launched together both claimed 3000, then coexisted on *:3000 and
        // [::1]:3000 with each health probe hitting the other's server. ingest() overwrites this with
        // the port actually bound if the framework ignores PORT and picks its own.
        lastKnownPort = pinnedPort
        // Auto-cleanup: reap any leftover/orphan dev process for this project (e.g. from a
        // previously force-killed Owl Monitor, reparented to launchd) before launching — both
        // whatever is holding the port we'll bind and any stray tree of this project — otherwise
        // the fresh server collides and exits ("code 6").
        // …but never reap BY PORT when a sibling supervised session owns that port. That can only
        // happen when an explicit `project.port` collides with another running project, and the
        // port rule SIGKILLs any JS server on it — i.e. it would silently kill a DIFFERENT project's
        // server to make room. Let this launch fail to bind instead, so the clash is visible. This
        // project's own leftover trees are still reaped (by path).
        reapLeftovers(pinnedPort: reservedPorts.contains(pinnedPort) ? nil : pinnedPort)
        let fwEnv = Self.frameworkEnv(for: project.framework)
        let userEnv = ProcessSupport.envAssignments(project.env)
        // Ownership tag first, so the whole tree carries it — see ProcessSupport.ownershipTag.
        let tag = ProcessSupport.ownershipTag(projectID: project.id, kind: commandOverride == nil ? "dev" : "preview")
        let launch = "\(tag)\(fwEnv)NODE_OPTIONS=\(ProcessSupport.nodeHeapFlag(memoryGB: memoryGB)) FORCE_COLOR=1 \(portEnv)exec \(baseCommand)"
        let command = "\(userEnv)\(launch)"
        append(line: ProcessSupport.displayCommand(env: project.env, rest: launch, cwd: project.path))

        guard let proc = SpawnedProcess.spawn(command: command, cwd: project.path, wantsStdin: true) else {
            lastError = "spawn failed — could not start the dev command"
            state = .failed("spawn failed")
            AppLog.shared.event("DevSession: spawn failed for \(project.name) — cmd: \(launch)")
            return
        }
        pid = proc.pid
        stdinFD = proc.stdinFD
        process = proc

        let stream = proc.chunks   // captured by the consume task; does NOT retain `proc`
        consumeTask = Task { @MainActor [weak self, weak proc] in
            for await chunk in stream {
                guard let self else { continue }
                switch chunk {
                case .data(let data): self.ingest(data)
                // THIS stream's process, never `self.process`: after a recycle or crash restart, the
                // old stream's EOF can land once the NEW process is already current — and cancelling
                // the new reader closed the relaunched server's pipe, killing it with SIGPIPE (exit
                // 13) on its next write. A fixed pre-relaunch delay used to hide the race.
                case .eof: proc?.cancelReader()
                case .exit(let code): self.handleExit(code: code)
                }
            }
        }

        // Warm-up safety net: many dev servers print "Local:" long before HTTP is ready
        // (e.g. MiddleSpace ~25s of Vite compile). We do NOT recycle during warm-up; only the
        // first successful HTTP probe flips to .running (see startHealth). If nothing ever
        // answers within the window (e.g. an API with no "/" route), assume it's up.
        let window = warmUpWindow
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard let self, !self.hasBeenHealthy, case .launching = self.state else { return }
            self.hasBeenHealthy = true
            self.state = .running(port: self.effectivePort ?? 3000)
            self.append(line: "warn: no HTTP within warm-up window — assuming running")
        }

        startSampling()
        startHealth()
    }

    /// Whether something is accepting TCP connections on `port` over loopback (IPv4 or IPv6) — i.e.
    /// the port is taken. Asks the kernel directly: a listener on the wildcard or on localhost answers
    /// a loopback connect, so this sees servers owned by ANY user and every port a process holds. (It
    /// replaces a walk of every process's fd table, which ran on the main actor once per candidate
    /// port, couldn't inspect other users' processes, and saw only one listening port per process.)
    /// A socket merely in TIME_WAIT refuses the connect, so a just-stopped server's port reads free —
    /// keeping a relaunch on its sticky port instead of drifting (3000→3001).
    nonisolated static func isPortInUse(_ port: Int) -> Bool {
        loopbackAccepts(port: port, ipv6: false) || loopbackAccepts(port: port, ipv6: true)
    }

    /// Non-blocking connect to 127.0.0.1 / ::1 on `port`, bounded by a short poll so a misbehaving
    /// listener can never stall the caller. Loopback answers at once either way (refused or
    /// accepted), so the 200 ms bound is a backstop, not a delay.
    nonisolated private static func loopbackAccepts(port: Int, ipv6: Bool) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let rc: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if rc == 0 { return true }                          // connected at once
        guard errno == EINPROGRESS else { return false }    // ECONNREFUSED — nothing listening
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 200) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// First port at/after `start` that's neither claimed by a sibling supervised session
    /// (`reservedPorts`) nor already accepting connections. Bounded so a pathological machine can't
    /// spin here; past the bound the framework's own fallback takes over from `start`.
    static func firstFreePort(from start: Int, avoiding reservedPorts: Set<Int>) -> Int {
        for port in start..<min(start + 200, 65536)
        where !reservedPorts.contains(port) && !isPortInUse(port) {
            return port
        }
        return start
    }

    /// Reap leftover/orphan dev processes for this project before (re)launching: anything holding
    /// the port we're about to bind, and any stray tree of this project (e.g. an orphan from a
    /// force-killed Owl Monitor, reparented to launchd). Conservative on purpose — only JS-runtime
    /// dev servers are touched, and editors / language servers that reference the same path are
    /// explicitly skipped, so we never kill VS Code, tsserver, an unrelated native service, etc.
    private func reapLeftovers(pinnedPort: Int?) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(dm_all_pids(&pids, 8192))
        guard count > 0 else { return }
        var nameBuf = [CChar](repeating: 0, count: 1024)
        var argsBuf = [CChar](repeating: 0, count: 8192)
        let jsRuntimes: Set<String> = ["node", "npm", "npx", "nuxt", "vite", "next", "pnpm", "yarn", "bun", "deno"]
        let editorMarkers = ["tsserver", "typescript/lib", "Code Helper", "Visual Studio Code",
                             ".vscode", "Cursor", "language-server", "languageserver", "eslintServer", "Electron"]
        let devTokens = ["nuxt", "vite", "next", "run dev", "astro", "remix", "webpack", "parcel", "node_modules/.bin"]
        for i in 0..<count {
            let p = pids[i]
            if p <= 1 || p == pid { continue }
            let comm = dm_proc_name(p, &nameBuf, 1024) > 0 ? String(cString: nameBuf).lowercased() : ""
            let args = dm_proc_args(p, &argsBuf, 8192) > 0 ? String(cString: argsBuf) : ""
            let isJS = jsRuntimes.contains(comm)
            let isEditor = editorMarkers.contains { args.contains($0) }
            let refsPath = Self.args(args, referencePath: project.path)
            // Only a non-editor JS runtime or a process referencing this project can ever be a
            // victim below — and the port check walks the process's whole fd table (the expensive
            // part of this sweep) — so skip the port scan for every other process on the machine.
            let couldBeVictim = !isEditor && (isJS || refsPath)
            let onPort = couldBeVictim && (pinnedPort.map { Int(dm_proc_listen_port(p)) == $0 } ?? false)
            // (a) holds the exact port we'll bind (a JS server or this project's process), or
            // (b) a leftover dev-server tree of THIS project still lingering.
            let projectVictim = isJS && !isEditor && refsPath
                && devTokens.contains { args.contains($0) }
            guard onPort || projectVictim else { continue }
            let pgid = getpgid(p)
            append(line: "cleanup: reaping leftover pid \(p) (\(comm))\(onPort ? " on port \(pinnedPort.map(String.init) ?? "")" : "")")
            if pgid > 1 { killpg(pgid, SIGKILL) }
            kill(p, SIGKILL)
        }
    }

    /// Framework-specific environment prefixed before the dev command (only where it belongs, so we
    /// don't pollute every framework's env):
    /// - **Nuxt** `NUXT_IGNORE_LOCK=1` — Owl Monitor is the single authority supervising one server
    ///   per project, so Nuxt's own dev-lock only gets in the way (a stale `nuxt.lock` from a
    ///   SIGKILLed run would block the relaunch); we dedupe ourselves.
    /// - **Astro** `ASTRO_DEV_BACKGROUND=0` — Astro 7 auto-daemonizes `astro dev` when it detects an
    ///   AI coding agent, so the spawned process would exit immediately and Owl Monitor would
    ///   loop-relaunch it; force the foreground so our one-supervised-process model holds.
    static func frameworkEnv(for framework: Framework) -> String {
        switch framework {
        case .nuxt:  return "NUXT_IGNORE_LOCK=1 "
        case .astro: return "ASTRO_DEV_BACKGROUND=0 "
        default:     return ""
        }
    }

    /// Whether `args` references `path` as a whole path component, not merely as a substring — so a
    /// project at `/p/foo` never reaps a sibling server at `/p/foobar`. The path counts as referenced
    /// only when the next character after the match is a path separator, whitespace, a quote, or the
    /// end of the argument string. Static + pure so it's unit-testable without spawning.
    static func args(_ args: String, referencePath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let boundaries: Set<Character> = ["/", " ", "\t", "\n", "\"", "'", ":"]
        var from = args.startIndex
        while let r = args.range(of: path, range: from..<args.endIndex) {
            if r.upperBound == args.endIndex || boundaries.contains(args[r.upperBound]) { return true }
            from = r.upperBound
        }
        return false
    }

    /// Clear the on-screen log (⌘K, like Terminal). Only the in-memory buffer: the on-disk log that
    /// `owl-monitor logs` and History read is left intact, and a line still being assembled stays in
    /// `lineBuffer`, so output arriving mid-line keeps flowing correctly.
    func clearLog() { logLines.removeAll() }

    /// Send a line of input to the running dev server's stdin.
    func sendInput(_ text: String) {
        guard stdinFD >= 0 else { return }
        let line = text + "\n"
        _ = line.withCString { ptr in write(stdinFD, ptr, strlen(ptr)) }
        append(line: "> \(text)")
    }

    private func closeStdin() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }

    func stop() {
        stopping = true
        recycling = false
        graceTask?.cancel()
        sampleTask?.cancel()
        healthTask?.cancel()
        closeStdin()
        guard pid > 0 else {
            state = .stopped(code: 0)
            return
        }
        let target = pid
        append(line: "stop: SIGTERM → kill tree \(target)")
        ProcessSupport.gracefulKillTree(target)
    }

    // MARK: - Output handling

    private func ingest(_ data: Data) {
        var fresh: [String] = []
        for line in lineBuffer.ingest(data) {
            let clean = line.strippedANSI
            if LogNoise.isShellNoise(clean) { continue }
            scanPort(clean)
            fresh.append(line)
        }
        append(lines: fresh)
    }

    /// Match the port in a URL the server prints, incl. IPv6 hosts in brackets — Vite/Nuxt dev
    /// print "Local: http://localhost:3000/", but a Nitro/node *preview* prints
    /// "Listening on http://[::]:3000", whose bracketed host the simpler pattern missed.
    ///
    /// NOTE: we do NOT flip to .running on the "ready" log line — the server is usually
    /// still compiling and not accepting HTTP yet. .running is set by the first successful
    /// health probe (startHealth), which is what prevents the recycle-during-warm-up loop.
    private func scanPort(_ clean: String) {
        if detectedPort == nil,
           let match = clean.firstMatch(of: /https?:\/\/(?:\[[^\]]*\]|[^\s:\/]+):(\d{2,5})/),
           let port = Int(match.1) {
            detectedPort = port
            lastKnownPort = port
        }
    }

    /// Append a whole chunk's lines as ONE observable mutation and ONE file write — `logLines` is
    /// observed, so per-line appends would re-render every observing view once per line during
    /// chatty output. Trimming keeps some slack and cuts in chunks: `removeFirst` is O(count) and
    /// shifts every kept row's ForEach offset, so doing it per line is quadratic-ish at the cap.
    private func append(lines: [String]) {
        guard !lines.isEmpty else { return }
        logLines.append(contentsOf: lines)
        if logLines.count > maxLogLines + trimSlack {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        if let data = lines.map({ $0.strippedANSI + "\n" }).joined().data(using: .utf8) {
            logFile?.write(data)
        }
    }

    private func append(line: String) { append(lines: [line]) }

    /// Mirrors this project's session log (ANSI-stripped) to its OWN file so it can be followed live
    /// from a terminal (`owl-monitor logs [path]`) and so one project's output never clobbers
    /// another's. Previous runs are retained (a crash log survives the next launch) up to a size cap.
    private func openLogFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Project.logsDirectory, withIntermediateDirectories: true)
        let url = project.logFileURL
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if !fm.fileExists(atPath: url.path) || size > 5_000_000 {
            fm.createFile(atPath: url.path, contents: Data())   // fresh start (new file or rotated)
        }
        logFile = try? FileHandle(forWritingTo: url)
        if logFile == nil { AppLog.shared.event("DevSession: could not open log file for \(project.name) at \(url.path)") }
        logFile?.seekToEndOfFile()
        if let header = "\n===== \(project.name) — new run =====\n".data(using: .utf8) {
            logFile?.write(header)
        }
    }

    private func handleExit(code: Int32) {
        graceTask?.cancel()
        sampleTask?.cancel()
        sampleTask = nil
        let exitedLeader = pid
        pid = 0
        // The leader is gone, but its children may not be: a SIGKILL on the leader (a crash, the
        // kernel's OOM killer) is never delivered to them, so they're reparented to launchd and keep
        // running — holding the port and RAM. Only an auto-restart's reapLeftovers ever caught them;
        // a give-up after the retry budget, or a Stop pressed after the crash (pid is 0 by then, so
        // stop() had nothing to kill), left them orphaned for good. Sweep the dead leader's session
        // right now — ProcessTree finds its members even with the leader dead. Harmless after a
        // deliberate stop/recycle, whose tree-kill has already done the same.
        if exitedLeader > 0 { ProcessSupport.gracefulKillTree(exitedLeader) }
        lastExitCode = code
        closeStdin()
        process?.release()

        if recycling {
            append(line: "recycle: old tree exited (code \(code)) — relaunching")
            relaunchAfterRecycle()
            return
        }

        healthTask?.cancel()
        healthTask = nil
        switch state {
        case .running, .launching, .degraded:
            append(line: "exit: process exited (code \(code))")
            if stopping || code == 0 {
                state = .stopped(code: 0)
                lastError = nil
            } else if looksLikeOOM(code), let bigger = biggerHeap() {
                // OOM → relaunch with the NEXT heap step (4→6→8). In AUTO mode persist the new level
                // (onHeapEscalated → autoHeapGB) so the next launch starts there, not back at 4.
                if project.memoryAuto { onHeapEscalated?(bigger) }
                lastError = "out of memory — relaunching with \(bigger) GB heap"
                append(line: "oom: out-of-memory detected — relaunching with \(bigger) GB heap")
                AppLog.shared.event("DevSession: \(project.name) OOM (exit \(code)) — retrying with \(bigger) GB")
                onEvent?(.oomRetry(project: project.name, newHeapGB: bigger))
                scheduleRestart(memoryGB: bigger, delaySeconds: 1)
            } else if hasBeenHealthy, crashRestarts < crashRestartLimit {
                // A server that WAS up then died → bounded auto-restart with exponential backoff
                // (1s, 2s, 4s). A server that never became healthy is left Failed (likely a config
                // error, not worth looping on).
                crashRestarts += 1
                let backoff = min(8, 1 << (crashRestarts - 1))
                lastError = "exited with code \(code) — auto-restarting (\(crashRestarts)/\(crashRestartLimit))"
                append(line: "crash: exit \(code) — auto-restarting in \(backoff)s (\(crashRestarts)/\(crashRestartLimit))")
                AppLog.shared.event("DevSession: \(project.name) crashed (exit \(code)) — auto-restart \(crashRestarts)/\(crashRestartLimit)")
                onEvent?(.crashed(project: project.name, code: code))
                scheduleRestart(memoryGB: lastMemoryGB, delaySeconds: backoff)
            } else {
                // Give up. Keep an OOM hint if that's what it looked like, else the plain exit cause.
                lastError = looksLikeOOM(code)
                    ? "out of memory — relaunch with more heap (e.g. owl-monitor up --gb \(biggerHeap() ?? lastMemoryGB))"
                    : "exited with code \(code)"
                state = .failed(lastError ?? "exited with code \(code)")
                onEvent?(.failed(project: project.name, reason: lastError ?? "exited with code \(code)"))
                AppLog.shared.event("DevSession: \(project.name) crashed (exit \(code)) — giving up after \(crashRestarts) auto-restarts")
            }
        default:
            append(line: "exit: process exited (code \(code))")
        }
    }

    /// Heuristic: did the recent output look like a V8 out-of-memory abort? (Robust to the exit code,
    /// which varies — SIGABRT 134, Nuxt 6, etc.)
    private func looksLikeOOM(_ exitCode: Int32) -> Bool {
        HeapScaling.looksLikeOOM(logLines: logLines, exitCode: exitCode)
    }

    /// The next heap to try after an OOM: the next step on the 4→6→8 ladder, capped at physical
    /// RAM. Returns nil when there's no higher step left.
    private func biggerHeap() -> Int? {
        let sysGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return HeapScaling.next(after: lastMemoryGB, systemGB: sysGB)
    }

    /// Relaunch after a delay (unless the user has since stopped us). During the backoff the state
    /// reads `.recycling` ("Recycling…", active) — not `.idle` — so an observer (human or agent
    /// polling `status`) sees it *recovering*, not dead. `.idle` is set only at the instant of
    /// relaunch so `start()`'s `!isActive` guard passes.
    private func scheduleRestart(memoryGB gb: Int, delaySeconds: Int) {
        state = .recycling
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            // Resolve the shell PATH off the main thread first, so start() finds it cached.
            await ShellEnvironment.refresh()
            guard let self, !self.stopping else { return }
            self.state = .idle
            self.start(memoryGB: gb)
        }
    }

    // MARK: - Metrics sampling (P2)

    private func startSampling() {
        prevTreeCPUns = 0
        prevWall = 0
        prevSysTicks = nil
        tick = 0
        treePids.removeAll()
        history.removeAll()
        sampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sampleOnce()
                // 2 s, matching the SystemSampler's cadence: each append re-renders the dashboard's
                // session charts, and 1 Hz doubled that Swift Charts work for no visible gain on
                // metrics that move in seconds. The 120-point history now spans ~4 min.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func sampleOnce() {
        let now = DispatchTime.now().uptimeNanoseconds

        var treeCPUns: Int64 = 0
        var treeMem: Int64 = 0
        if pid > 0 {
            if treePids.isEmpty || tick % treeRefreshTicks == 0 {
                treePids = ProcessTree.sessionMembers(of: pid)
            }
            for p in treePids {
                let st = dm_proc_stat_for(p)
                if st.valid == 1 {
                    treeCPUns += st.cpu_time_ns
                    treeMem += st.phys_footprint
                }
            }
        }
        var treeCPU = 0.0
        if prevWall > 0, treeCPUns >= prevTreeCPUns {
            let dt = Double(now - prevWall)
            if dt > 0 { treeCPU = Double(treeCPUns - prevTreeCPUns) / dt * 100 }
        }
        prevTreeCPUns = treeCPUns
        prevWall = now

        var ticks = dm_cpu_ticks()
        _ = dm_system_cpu_ticks(&ticks)
        var sysCPU = 0.0
        if let prev = prevSysTicks {
            let dTotal = Double(ticks.total &- prev.total)
            let dIdle = Double(ticks.idle &- prev.idle)
            if dTotal > 0 { sysCPU = max(0, min(100, (1 - dIdle / dTotal) * 100)) }
        }
        prevSysTicks = ticks

        var mem = dm_mem_info()
        _ = dm_system_mem(&mem)

        let point = MetricPoint(
            id: tick,
            systemCPU: sysCPU,
            systemMemUsed: Double(mem.used),
            systemMemTotal: Double(mem.total),
            treeCPU: treeCPU,
            treeMem: Double(treeMem),
            buildCPU: 0,
            orphanCPU: 0,
            loadAvg: dm_load_avg()
        )
        tick += 1
        history.append(point)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    // MARK: - Health & recycle (P3)

    private func startHealth() {
        strikes = 0
        stableProbes = 0
        hasBeenHealthy = false
        healthTask = Task { @MainActor [weak self] in
            // Probe a bit more often while warming up so we flip to .running promptly.
            while !Task.isCancelled {
                guard let self else { return }
                let interval: Duration = self.hasBeenHealthy ? self.probeInterval : .seconds(1)
                try? await Task.sleep(for: interval)
                switch self.state {
                case .stopped, .failed, .recycling, .idle: continue
                default: break
                }
                guard let port = self.effectivePort else { continue }
                // While warming up use a SHORT timeout: a server that's still compiling can accept the
                // connection and hold it, which would otherwise block this loop for the full (load-
                // tolerant) timeout and delay the flip to .running. Once healthy, use the long one.
                let timeout = self.hasBeenHealthy ? self.httpTimeout : self.warmHTTPTimeout
                let alive = await Self.probe(port: port, path: self.project.effectiveHealthPath, timeout: timeout)
                if Task.isCancelled || self.stopping || self.recycling { continue }

                if alive {
                    let recovering = self.hasBeenHealthy && self.strikes > 0
                    let firstTime = !self.hasBeenHealthy
                    self.hasBeenHealthy = true
                    self.strikes = 0
                    // Restore the crash-recovery budget only after a STABLE streak of healthy
                    // probes — so a server that flaps (heal → crash → heal …) still hits the
                    // restart cap instead of auto-restarting forever.
                    self.lastError = nil   // it's responding now — clear any stale failure cause
                    self.stableProbes += 1
                    if self.stableProbes >= self.stableProbesToReset {
                        self.crashRestarts = 0
                    }
                    if firstTime { self.append(line: "ok: server is responding on :\(port)") }
                    if recovering {
                        self.append(line: "ok: health recovered")
                        self.onEvent?(.recovered(project: self.project.name))
                    }
                    self.state = .running(port: port)
                } else if self.hasBeenHealthy {
                    self.stableProbes = 0
                    // Was healthy and stopped responding → strike toward recycle.
                    self.strikes += 1
                    self.append(line: "warn: health probe failed (\(self.strikes)/\(self.strikeLimit))")
                    if self.strikes >= self.strikeLimit {
                        self.recycle()
                    } else {
                        self.state = .degraded(strikes: self.strikes)
                        self.onEvent?(.hung(project: self.project.name))
                    }
                }
                // else: still warming up (server has never answered yet) — keep waiting,
                // do NOT recycle. The grace task assumes-running after the warm-up window.
            }
        }
    }

    private static func probe(port: Int, path: String = "/", timeout: TimeInterval) async -> Bool {
        // Use "localhost" (not 127.0.0.1): many dev servers bind IPv6 [::1] only, so an IPv4-only
        // probe gets "connection refused" and the server appears stuck in "Launching" forever.
        // ANY HTTP response (200, 404, 500, …) means the server is alive — URLSession only throws on
        // a transport failure (refused/timeout), so this is a liveness check, not a correctness one.
        guard let url = URL(string: "http://localhost:\(port)\(path.hasPrefix("/") ? path : "/" + path)")
        else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "GET"
        do {
            _ = try await URLSession.shared.data(for: req)
            return true
        } catch {
            return false
        }
    }

    /// Kill the whole tree and relaunch with the last memory setting.
    func recycle() {
        guard !recycling else { return }
        recycling = true
        recycleCount += 1
        state = .recycling
        append(line: "recycle: kill tree + relaunch")
        onEvent?(.recycled(project: project.name))
        AppLog.shared.event("DevSession: recycling \(project.name) (recycle #\(recycleCount), port \(effectivePort.map(String.init) ?? "?"))")
        healthTask?.cancel()
        sampleTask?.cancel()
        graceTask?.cancel()
        if pid > 0 {
            ProcessSupport.gracefulKillTree(pid)
            // handleExit() fires on exit and calls relaunchAfterRecycle().
        } else {
            relaunchAfterRecycle()
        }
    }

    private func relaunchAfterRecycle() {
        recycling = false
        state = .idle  // clear "active" so start() proceeds
        let gb = lastMemoryGB
        let port = project.port ?? lastKnownPort
        Task { @MainActor [weak self] in
            // Relaunch as soon as the old server has actually let go of its port, not after a fixed
            // delay. The tree's leader (e.g. `pnpm`) exits first; its listening child (`node`) can
            // hold the socket a beat longer — and start() treats a busy sticky port as taken, which
            // would drift the server 3000→3001. Poll (a cheap loopback connect) for up to ~3 s, which
            // also relaunches FASTER than the old flat 400 ms whenever the port frees sooner.
            if let port {
                var polls = 0
                while polls < 30, Self.isPortInUse(port) {
                    try? await Task.sleep(for: .milliseconds(100))
                    polls += 1
                }
            } else {
                try? await Task.sleep(for: .milliseconds(400))
            }
            await ShellEnvironment.refresh()   // off the main thread, so start() finds it cached
            self?.start(memoryGB: gb)
        }
    }
}
