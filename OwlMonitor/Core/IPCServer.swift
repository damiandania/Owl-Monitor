import Foundation
import Darwin

/// Unix-socket hub: lets `owl-monitor` CLIs launch, build and query dev servers through the app.
/// One supervised server per project (several projects can run at once); the accept loop runs on
/// a background queue and dispatches request handling to the main actor.
@MainActor
final class IPCServer {
    private var listenFD: Int32 = -1
    private weak var app: AppState?

    func start(app: AppState) {
        self.app = app
        let dir = (IPCSocket.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = dm_ipc_listen(IPCSocket.path)
        guard fd >= 0 else {
            // -2: another Owl Monitor instance already owns the hub socket. Don't steal it (that
            // races two hubs against each other). This instance simply runs without a hub; in normal
            // use macOS keeps a single instance, so this only guards against a launch race.
            if fd == -2 {
                AppLog.shared.event("IPCServer: a Owl Monitor hub is already listening — not taking over the socket")
            }
            return
        }
        listenFD = fd

        let queue = DispatchQueue(label: "ipc.accept")
        queue.async { [weak self] in
            while true {
                let client = dm_ipc_accept(fd)
                if client < 0 { break }
                // Only the user who owns the hub may drive it (run/stop/build/remove). A connection
                // from another UID is refused and dropped — but we must NOT break the accept loop
                // (that would take the whole hub down), so this is `continue`, not a fatal return.
                if dm_ipc_peer_uid(client) != Int32(getuid()) {
                    IPCIO.write(client, IPCMessage(type: "error", message: "unauthorized"))
                    close(client)
                    continue
                }
                guard let reqData = IPCIO.readLine(client),
                      let req = try? JSONDecoder().decode(IPCRequest.self, from: reqData) else {
                    IPCIO.write(client, IPCMessage(type: "error", message: "bad request"))
                    close(client)
                    continue
                }
                Task { @MainActor in
                    await self?.handle(req, client: client)
                }
            }
        }
    }

    /// Stop the hub on quit: close the listening socket (which breaks the accept loop) and remove the
    /// socket file so a stale one isn't left behind. Best-effort; called from `AppState.shutdown()`.
    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        try? FileManager.default.removeItem(atPath: IPCSocket.path)
    }

    private func handle(_ req: IPCRequest, client: Int32) async {
        defer { close(client) }
        guard let app else {
            IPCIO.write(client, IPCMessage(type: "error", message: "app unavailable"))
            return
        }
        switch req.cmd {
        case "status":
            // Report EVERY persisted project (not just live sessions), so `status` matches
            // projects.json and a crashed/idle project still appears (and exposes its log path).
            let servers = app.projects.sorted { $0.name < $1.name }.map { Self.serverInfo(for: $0, app: app) }
            IPCIO.write(client, IPCMessage(type: "status", servers: servers))

        case "run", "up":
            guard let project = resolveProject(req, app: app, client: client) else { return }
            // Don't interrupt an in-flight build: launching a dev server stops siblings (incl. the
            // build). Report it as "busy" so the CLI/another Claude waits it out (with --wait) instead
            // of aborting the build. See buildBusyMessage.
            if let busy = Self.buildBusyMessage(project, app: app) {
                IPCIO.write(client, IPCMessage(type: "busy", message: busy)); return
            }
            // An explicit --gb means "use exactly this heap" → pin it AND turn auto off, otherwise
            // auto mode would override it with the framework default.
            if let gb = req.gb {
                app.setMemoryGB(gb, for: project.id)
                app.setMemoryAuto(false, for: project.id)
            }
            app.selectedProjectID = project.id
            // Idempotent: if this project's server is already supervised, report it, don't relaunch.
            if let existing = app.sessions[project.id], existing.state.isActive {
                let port = existing.effectivePort.map { " on :\($0)" } ?? ""
                IPCIO.write(client, IPCMessage(type: "ok", message: "\(project.name) already running\(port)"))
                return
            }
            guard let toLaunch = app.projects.first(where: { $0.id == project.id }) else {
                IPCIO.write(client, IPCMessage(type: "error", message: "project vanished before launch")); return
            }
            // Resolve the login-shell PATH off the main thread (the CLI is waiting on us anyway), so
            // the launch itself doesn't freeze the UI on it — see ShellEnvironment.
            await ShellEnvironment.refresh()
            app.launch(toLaunch)
            // Report the heap the server actually got, and why it's smaller when it is: capped to
            // physical RAM (an explicit `--gb 99` on an 8 GB machine), or trimmed by the shared-memory
            // budget because other servers are running — never a silent shrink.
            let learned = app.effectiveMemoryGB(for: toLaunch)
            let gb = app.sessions[toLaunch.id]?.lastMemoryGB ?? learned
            let requested = toLaunch.memoryAuto ? Detector.defaultMemoryGB(for: toLaunch.framework) : toLaunch.memoryGB
            let capNote = gb < learned
                ? " — shared: trimmed from \(learned) GB so the servers running fit \(app.systemRAMGB) GB RAM"
                : gb < requested ? " — capped from \(requested) GB to fit \(app.systemRAMGB) GB RAM" : ""
            IPCIO.write(client, IPCMessage(type: "ok",
                message: "launched \(toLaunch.name) (\(toLaunch.framework.displayName), \(gb) GB\(capNote))"))

        case "preview":
            guard let project = resolveProject(req, app: app, client: client) else { return }
            guard project.previewCommand != nil else {
                IPCIO.write(client, IPCMessage(type: "error",
                    message: "no preview command for \(project.name) — needs a `preview` script (or a `start` script alongside `dev`)"))
                return
            }
            if let busy = Self.buildBusyMessage(project, app: app) {
                IPCIO.write(client, IPCMessage(type: "busy", message: busy)); return
            }
            // An explicit --gb overrides the BUILD heap (previews serve the production build), and
            // turns auto off, mirroring how `up --gb` pins the dev-server heap.
            if let gb = req.gb {
                app.setBuildMemoryGB(gb, for: project.id)
                app.setBuildMemoryAuto(false, for: project.id)
            }
            app.selectedProjectID = project.id
            if let existing = app.previews[project.id], existing.state.isActive {
                let port = existing.effectivePort.map { " on :\($0)" } ?? ""
                IPCIO.write(client, IPCMessage(type: "ok", message: "\(project.name) preview already running\(port)"))
                return
            }
            guard let toLaunch = app.projects.first(where: { $0.id == project.id }) else {
                IPCIO.write(client, IPCMessage(type: "error", message: "project vanished before launch")); return
            }
            await ShellEnvironment.refresh()   // off the main thread — see the `up` case
            app.startPreview(toLaunch)
            let learned = app.effectiveBuildMemoryGB(for: toLaunch)
            let gb = app.previews[toLaunch.id]?.lastMemoryGB ?? learned
            let shared = gb < learned ? " — shared: trimmed from \(learned) GB so the servers running fit \(app.systemRAMGB) GB RAM" : ""
            IPCIO.write(client, IPCMessage(type: "ok", message: "launched \(toLaunch.name) preview (\(gb) GB\(shared))"))

        case "build":
            guard let project = resolveProject(req, app: app, client: client) else { return }
            app.selectedProjectID = project.id
            // Synchronous: run the build to completion (leaving the dev server untouched, like
            // runBuild), then stream the tail of its output followed by an ok/error verdict. The
            // CLI prints every message and exits non-zero on the trailing "error" — so a caller
            // (or an agent) gets the real result instead of a fire-and-forget "building …".
            let build = await app.runBuildAndWait(project)
            let code = build.result ?? -1
            // On failure show a deeper tail (errors are what the caller came for); on success a short
            // one. Either way the WHOLE build log is on disk, so point there for anything the tail
            // clips — e.g. a Rollup error whose header scrolls past any fixed-size tail.
            for line in build.logLines.suffix(code == 0 ? 40 : 200) {
                IPCIO.write(client, IPCMessage(type: "ok", message: line))
            }
            if code == 0 {
                IPCIO.write(client, IPCMessage(type: "ok", message: "✅ build succeeded — \(project.name) (exit 0)"))
            } else {
                IPCIO.write(client, IPCMessage(type: "ok", message: "↳ full build log: \(project.buildLogFileURL.path)"))
                IPCIO.write(client, IPCMessage(type: "error", message: "❌ build failed — \(project.name) (exit \(code))"))
            }

        case "stop":
            if req.force == true {
                // Close everything for the project (or for every project with --all): see forceClose.
                let targets: [Project]
                if req.all == true { targets = app.projects }
                else if let path = req.path, let p = app.projects.first(where: { $0.path == path }) { targets = [p] }
                else {
                    IPCIO.write(client, IPCMessage(type: "error",
                        message: "no project tracked for this path (use --all to close everything)"))
                    return
                }
                for project in targets {
                    let r = await app.forceClose(project)
                    let what = r.closed.isEmpty ? "nothing was running" : "stopped \(r.closed.joined(separator: ", "))"
                    let orphans = r.orphans > 0 ? "; reaped \(r.orphans) orphaned process tree\(r.orphans == 1 ? "" : "s")" : ""
                    IPCIO.write(client, IPCMessage(type: "ok", message: "closed \(project.name): \(what)\(orphans)"))
                }
            } else if req.all == true {
                app.stopAllSessions()
                IPCIO.write(client, IPCMessage(type: "ok", message: "stopped all servers"))
            } else if let path = req.path, let project = app.projects.first(where: { $0.path == path }) {
                app.stop(project)
                app.stopPreview(project)   // preview and dev are mutually exclusive — stop whichever runs
                IPCIO.write(client, IPCMessage(type: "ok", message: "stopped \(project.name)"))
            } else {
                IPCIO.write(client, IPCMessage(type: "error",
                    message: "no server tracked for this path (use --all to stop everything)"))
            }

        case "restart":
            // Relaunch in ANY state — restart is most needed precisely when a server has Failed.
            guard let path = req.path, let project = app.projects.first(where: { $0.path == path }) else {
                IPCIO.write(client, IPCMessage(type: "error",
                    message: "no project tracked for this path — run 'up' here first")); return
            }
            app.selectedProjectID = project.id
            await ShellEnvironment.refresh()   // off the main thread — see the `up` case
            if let session = app.sessions[project.id], session.state.isActive {
                session.recycle()
                IPCIO.write(client, IPCMessage(type: "ok", message: "restarting \(project.name)"))
            } else {
                app.launch(project)
                IPCIO.write(client, IPCMessage(type: "ok", message: "relaunching \(project.name)"))
            }

        case "remove":
            guard let path = req.path, let project = app.projects.first(where: { $0.path == path }) else {
                IPCIO.write(client, IPCMessage(type: "error", message: "no project tracked for this path")); return
            }
            let name = project.name
            app.removeProject(project.id)   // stops its server/build, then forgets it
            IPCIO.write(client, IPCMessage(type: "ok", message: "removed \(name)"))

        case "awake":
            // Keep-awake is the same SleepGuard the toolbar cup drives, so what the CLI does is what the
            // app shows. Replies with the state AFTER the action, so the caller sees what really happened.
            let guardian = app.sleepGuard
            switch req.sub ?? "status" {
            case "status": break
            case "off": guardian.disable()
            case "add":
                guard let m = req.minutes, (1...1440).contains(m) else {
                    IPCIO.write(client, IPCMessage(type: "error", message: "awake add needs minutes between 1 and 1440"))
                    return
                }
                guardian.add(TimeInterval(m) * 60)
            default:
                IPCIO.write(client, IPCMessage(type: "error", message: "unknown awake command (use status, add <minutes>, off)"))
                return
            }
            let snap = guardian.snapshot()
            IPCIO.write(client, IPCMessage(type: "ok", message: req.json == true ? snap.json : snap.text))

        case "quota":
            guard let claude = app.claudeQuota, let codex = app.codexQuota else {
                IPCIO.write(client, IPCMessage(type: "error", message: "quota monitors not ready yet — try again in a moment"))
                return
            }
            // The Codex monitor normally starts only when the notch is switched to GPT; the first ask
            // starts it (once — it then refreshes itself every 10 min), so the first reply may say `pending`.
            codex.ensureRunning()
            // `quota show claude|codex` and `quota toggle` change what the notch shows (the same switch as
            // clicking it); they return at once with the new state.
            switch req.sub {
            case "claude": app.showQuota(.claude)
            case "codex": app.showQuota(.gpt)
            case "toggle": app.showQuota(app.shownQuotaSource == .claude ? .gpt : .claude)
            case nil: break
            default:
                IPCIO.write(client, IPCMessage(type: "error", message: "unknown quota command (use show claude|codex, toggle)"))
                return
            }
            if req.refresh == true {
                let before = (claude.updatedAt, codex.updatedAt)
                claude.refresh(); codex.refresh()
                // Wait for both to publish (a Claude probe takes a few seconds), but never forever.
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if claude.updatedAt != before.0, codex.updatedAt != before.1 { break }
                }
            }
            let c = Self.quotaProvider(claude), x = Self.quotaProvider(codex)
            let shown = app.shownQuotaSource == .gpt ? "codex" : "claude"
            IPCIO.write(client, IPCMessage(type: "ok",
                message: req.json == true ? QuotaReport.json(claude: c, codex: x, shown: shown)
                                          : QuotaReport.text(claude: c, codex: x, shown: shown)))

        default:
            IPCIO.write(client, IPCMessage(type: "error", message: "unknown command"))
        }
    }

    /// One project's entry in `status`: its state, port, logs, icon and build coordination.
    private static func serverInfo(for p: Project, app: AppState) -> IPCServerInfo {
        let s = app.sessions[p.id]
        let preview = app.previews[p.id]
        // Dev and preview are mutually exclusive per project (stopSiblings) — surface whichever is
        // actually active, so a running preview shows up in `status`/`--wait` too, instead of always
        // reporting the (idle) dev session.
        let active: DevSession?
        if s?.state.isActive == true { active = s }
        else if preview?.state.isActive == true { active = preview }
        else { active = s }
        let build = app.builds[p.id]
        let building = build?.isRunning ?? false

        var info = IPCServerInfo(name: p.name, path: p.path, state: active?.state.label ?? "Idle",
                                 port: active?.effectivePort ?? p.port, logPath: p.logFileURL.path)
        info.buildLogPath = p.buildLogFileURL.path
        info.iconPath = ProjectIconView.faviconPath(for: p.path)
        info.iconSymbol = p.framework.symbolName
        info.ready = active?.isReady ?? false
        info.url = active.flatMap { $0.isReady ? $0.url : nil }
        info.pid = (active?.pid).flatMap { $0 > 0 ? Int($0) : nil }
        info.exitCode = (active?.lastExitCode).map { Int($0) }
        info.lastError = active?.lastError
        if let active, let elapsed = active.launchElapsed {
            info.launchElapsed = elapsed
            info.launchETA = active === preview ? p.lastPreviewLaunchSeconds : p.lastLaunchSeconds
        }
        if building {
            info.building = true
            info.buildElapsed = build?.startedAt.map { Date().timeIntervalSince($0) }
            info.buildETA = p.lastBuildSeconds
        }
        return info
    }

    private static func quotaProvider(_ m: ClaudeQuotaMonitor) -> QuotaReport.Provider {
        .init(status: m.status, stale: m.isStale, updatedAt: m.updatedAt,
              session: m.fiveHour.map { .init(usedPercent: $0, resetsAt: m.fiveHourResetsAt, windowMinutes: 300) },
              weekly: m.sevenDay.map { .init(usedPercent: $0, resetsAt: m.sevenDayResetsAt, windowMinutes: 10080) })
    }

    private static func quotaProvider(_ m: CodexQuotaMonitor) -> QuotaReport.Provider {
        let windows = [m.primary, m.secondary].compactMap { $0 }.map {
            QuotaReport.Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, windowMinutes: $0.durationMinutes)
        }
        let c = QuotaReport.classify(windows)
        return .init(status: m.status, stale: m.isStale, updatedAt: m.updatedAt,
                     session: c.session, weekly: c.weekly, other: c.other)
    }

    /// Resolve the request's `path` to a known (or newly added) project. Writes an error and returns
    /// nil when the path is missing or isn't a launchable project folder — so a bogus `up <path>`
    /// never creates a junk entry. Shared by run/up/build.
    private func resolveProject(_ req: IPCRequest, app: AppState, client: Int32) -> Project? {
        guard let path = req.path else {
            IPCIO.write(client, IPCMessage(type: "error", message: "missing path")); return nil
        }
        if let existing = app.projects.first(where: { $0.path == path }) { return existing }
        guard Detector.isProject(path: path) else {
            IPCIO.write(client, IPCMessage(type: "error",
                message: "not a project: \(path)\n  (need an existing folder with a package.json / deno config)"))
            return nil
        }
        guard let project = app.addProject(path: path) else {
            IPCIO.write(client, IPCMessage(type: "error", message: "could not add project")); return nil
        }
        return project
    }

    /// If ANY build is running (this project's OR another's), an agent-directed "busy" message; nil
    /// when nothing is building. Two reasons a launch waits, not just the same-project mutual
    /// exclusion: (1) this project's own build stops its server first, so the server can only start
    /// after it; (2) a build on a RAM-constrained Mac PAUSES every other project's dev server to
    /// claim the memory (see `pauseActiveServersForBuild`), so launching a different project mid-build
    /// both fights the build for RAM and would be paused anyway. The CLI waits on this reply and
    /// relaunches once builds clear, so the message tells the agent exactly that — keep listening,
    /// Owl Monitor will start it automatically, don't work around it.
    private static func buildBusyMessage(_ project: Project, app: AppState) -> String? {
        let running = app.builds.values.filter { $0.isRunning }
        guard !running.isEmpty else { return nil }
        let parts = running.map { b -> String in
            let elapsed = b.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let eta = b.project.lastBuildSeconds.map { " / ~\(Int($0))s" } ?? ""
            return "\(b.project.name) (\(elapsed)s\(eta))"
        }.sorted()
        let which = parts.count == 1 ? "A build is in progress: \(parts[0])."
                                     : "Builds are in progress: \(parts.joined(separator: ", "))."
        let sameProject = running.contains { $0.project.id == project.id }
        let why = sameProject
            ? "\(project.name)'s build stops its server first, so the server can only start once the build finishes."
            : "On this RAM-constrained Mac a build pauses every dev server to free memory, so starting \(project.name) now would fight the build for RAM and be paused anyway."
        return "\(which) \(why) Owl Monitor will start \(project.name) automatically as soon as the "
            + "build finishes — do NOT retry, run the build yourself, kill the build, or launch the "
            + "server unsupervised. Waiting now; keep listening for the ready line."
    }
}
