import Foundation
import Observation
import AppKit
import Darwin

/// Root observable app state. Owns the project list, selection and the active session.
@MainActor
@Observable
final class AppState {
    var projects: [Project] = []
    var selectedProjectID: Project.ID?
    /// One supervised server PER PROJECT, keyed by project id. Several projects can run at once.
    var sessions: [Project.ID: DevSession] = [:]
    /// One build per project, keyed by project id.
    var builds: [Project.ID: BuildRunner] = [:]
    /// One long-running background worker per project, keyed by project id.
    var workers: [Project.ID: WorkerRunner] = [:]
    /// One production-build preview server per project — a DevSession running the project's preview
    /// command, so it reuses all the server supervision (port, health, logs).
    var previews: [Project.ID: DevSession] = [:]
    /// Selected tab in the GLOBAL terminal panel: "s:<projectID>" (server), "b:<projectID>" (build)
    /// or "w:<projectID>" (worker).
    var selectedTerminalID: String?

    /// App-wide settings (browser, analysis model, …) — the gear at the bottom of the sidebar.
    var settings: AppSettings

    /// Locale the UI renders in: the chosen language, or the system locale for "system". Applied as a
    /// live `.environment(\.locale,)` override on every scene, so changing the language re-localizes
    /// the UI immediately (no relaunch) — `AppleLanguages` still pins the choice for the next launch.
    var uiLocale: Locale {
        settings.language == "system" ? .autoupdatingCurrent : Locale(identifier: settings.language)
    }
    /// Browsers installed on this Mac (display names), for the "open in" picker.
    var installedBrowsers: [String] = []
    /// Code editors installed on this Mac, for the "Code" button picker.
    var installedEditors: [String] = []

    @ObservationIgnored private let store = ProjectStore()
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let ipcServer = IPCServer()
    @ObservationIgnored let eventStore = EventStore()
    let systemSampler = SystemSampler()
    let sleepGuard = SleepGuard()

    init() {
        // Adopt anything left behind by the pre-rename "Dev Monitor" — its Application Support folder,
        // its ~/.local/bin/dev-monitor symlink, its Claude hook. MUST come before the load() calls
        // below: the stores are property defaults, so they already exist and would otherwise read an
        // empty new folder and quietly fall back to defaults, looking like data loss.
        LegacyMigration.run()
        // The IPC hub writes responses to `owl-monitor` clients that may have already closed the
        // socket (a CLI reads its reply and exits). Without ignoring SIGPIPE, that write delivers
        // the signal whose default action TERMINATES the whole app — which is exactly why the app
        // appeared to "die" right after handling an `up`/`status` command (the dev server it had
        // already spawned survives, since it runs in its own session). The CLI guards against this;
        // the hub side must too. Set before IPCServer.start() below begins accepting/writing.
        signal(SIGPIPE, SIG_IGN)
        let loadedSettings = settingsStore.load()
        settings = loadedSettings.settings
        // Mirror the saved UI language into AppleLanguages so the next launch honours it (and this one
        // does too if it was already set). "system" clears the override.
        AppSettings.applyLanguage(settings.language)
        // Apply the saved theme once the run loop is up — NSApp is nil during SwiftUI App.init.
        let theme = settings.theme
        Task { @MainActor in AppSettings.applyAppearance(theme) }
        let loadedProjects = store.load()
        projects = loadedProjects.projects
        // Drop entries whose folder no longer exists (stale/junk paths) so `status`, the sidebar
        // and projects.json stay in sync with reality. Missing folders can never be launched anyway.
        let onDisk = projects.filter { FileManager.default.fileExists(atPath: $0.path) }
        if onDisk.count != projects.count {
            AppLog.shared.event("Startup: pruned \(projects.count - onDisk.count) project(s) with a missing folder")
            projects = onDisk
            store.save(projects)
        }
        // Backfill worker commands for projects saved before workers existed (and keep them in sync).
        refreshWorkerCommands()
        installedBrowsers = BrowserList.installed()
        installedEditors = EditorList.installed()
        selectedProjectID = projects.first?.id
        // Richer startup line than a bare "Owl Monitor started" — version + project count + physical
        // RAM, so a post-mortem (or the Doctor's Live Scan) has context about the machine and load.
        let ramGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        AppLog.shared.event("Startup: Owl Monitor \(version) · \(projects.count) project(s) · \(ramGB) GB RAM")
        ipcServer.start(app: self)
        systemSampler.start()
        // The callbacks hand the sampler LEADER pids only — tree membership is resolved during the
        // sampler's background pass (one sid-grouping sweep for everything), never on the main actor.
        systemSampler.devServerInfo = { [weak self] in
            guard let self else { return [] }
            // One entry PER supervised server — dev servers AND production-build previews (both are
            // DevSessions) — each its own table row. id = -pid so the synthetic row never collides
            // with a real pid and skips enrichment. `isPreview` gets the row an eye icon in the
            // Activity table instead of the " · preview" text suffix it used to carry in the name.
            var rows: [(id: Int32, leader: pid_t, label: String, isPreview: Bool)] = []
            for s in self.sessions.values where s.pid > 0 {
                rows.append((id: -s.pid, leader: s.pid,
                             label: s.project.name + (s.effectivePort.map { " :\($0)" } ?? ""),
                             isPreview: false))
            }
            for p in self.previews.values where p.pid > 0 {
                rows.append((id: -p.pid, leader: p.pid,
                             label: p.project.name + (p.effectivePort.map { " :\($0)" } ?? ""),
                             isPreview: true))
            }
            return rows
        }
        systemSampler.buildInfo = { [weak self] in
            guard let self else { return nil }
            let live = self.builds.values.filter { $0.isRunning && $0.pid > 0 }
            guard !live.isEmpty else { return nil }
            let label = live.count == 1 ? "Build · \(live.first?.project.name ?? "build")" : "\(live.count) builds"
            return (leaders: live.map(\.pid), label: label)
        }
        systemSampler.workerInfo = { [weak self] in
            guard let self else { return [] }
            // One entry PER running worker (its own highlighted row, like a supervised server).
            // id = -pid so the synthetic row never collides with a real pid and skips enrichment.
            return self.workers.values
                .filter { $0.isRunning && $0.pid > 0 }
                .map { (id: -$0.pid, leader: $0.pid, label: "\($0.project.name) · worker") }
        }
        pressure = PressureManager(app: self)
        liveScan = LiveScan(app: self)
        systemSampler.onStuck = { [weak self] in self?.pressure.evaluate() }
        // Refresh the pressure suggestions every 30s: prune dead processes, clear once the machine
        // recovers (the yellow tab disappears), or re-evaluate while still stuck. Also edge-check
        // swap: warn once when it climbs past the high-swap threshold (distinct from the stuck-machine
        // pressure alert), recommending the user close idle projects before it starts thrashing.
        Task { @MainActor [weak self] in
            // Launch: clean up — and bring back — any servers a previous, unexpectedly-ended session
            // left running unsupervised. Then the same sweep runs on every tick as a safety net.
            // (PATH is warmed first, off the main thread, so those relaunches don't block on it.)
            ShellEnvironment.prefetch()
            self?.sweepOrphans(recover: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.pressure.tick()
                self.checkSwapPressure()
                self.checkExternalProcesses()
                self.sweepOrphans(recover: false)
                self.checkIdleServers()
            }
        }
        // Wire notifications: set the UN delegate (foreground presentation + action routing),
        // register actionable categories, and request authorization.
        Notifier.shared.attach(app: self)
        // Surface a corrupt store (now that the notifier is attached): the file was backed up and we
        // started from defaults, so the user knows their settings / projects were reset — and where
        // the backup is — instead of silently losing them.
        if let backup = loadedSettings.corruptBackup {
            route(NotificationPolicy.storeCorrupted(what: "Settings", backup: backup))
        }
        if let backup = loadedProjects.corruptBackup {
            route(NotificationPolicy.storeCorrupted(what: "Project list", backup: backup))
        }
        // Clean up on quit: stop every supervised server/build so none is left orphaned holding a
        // port — they run in their own session (SETSID) and would otherwise outlive the app.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    /// Aggregate health for the menu-bar status glyph across EVERY supervised process (dev servers,
    /// previews, workers, builds), by priority: red (any failed OR stopped) > orange (any starting /
    /// building) > green (any running) > idle (none).
    enum ServerHealth { case idle, green, orange, red }
    var serversHealth: ServerHealth {
        var orange = false, green = false
        // Dev servers + previews (both DevSessions).
        for s in Array(sessions.values) + Array(previews.values) {
            switch s.state {
            case .failed, .stopped:                    return .red
            case .launching, .recycling, .degraded:    orange = true
            case .running:                             green = true
            case .idle:                                break
            }
        }
        for w in workers.values {
            if w.didCrash || (w.lastExitCode != nil && !w.isRunning) { return .red }   // crashed/stopped
            if w.isRunning { green = true }
        }
        for b in builds.values {
            if b.isRunning { orange = true }
            else if let code = b.result, code != 0 { return .red }   // failed or user-stopped
        }
        if orange { return .orange }
        if green { return .green }
        return .idle
    }

    /// Whether the selected project's build is currently running (drives the toolbar "Build Running"
    /// label shown to the left of the build button).
    var isSelectedBuildRunning: Bool {
        guard let p = selectedProject else { return false }
        return build(for: p)?.isRunning ?? false
    }

    // MARK: - Notifications

    /// The last 5 notifications (most-recent first) shown in the sidebar feed.
    var recentNotifications: [NotificationItem] = []
    /// Banner de-dup: last time a given key posted a system banner (the feed records everything).
    @ObservationIgnored private var lastNotified: [String: Date] = [:]

    /// Single funnel for every notification: record it in the in-app feed, then post a system banner
    /// if its category is enabled and it isn't a throttled repeat.
    func route(_ item: NotificationItem) {
        recentNotifications.insert(item, at: 0)
        if recentNotifications.count > 5 { recentNotifications.removeLast(recentNotifications.count - 5) }
        // Persist to the on-disk history (survives restart; the in-app feed only keeps the last 5).
        let projectName = item.projectID.flatMap { id in projects.first { $0.id == id }?.name }
        eventStore.append(PersistedEvent(id: item.id, date: item.date, category: item.category,
                                         urgent: item.severity == .urgent, title: item.title,
                                         body: item.body, projectID: item.projectID, projectName: projectName))
        guard NotificationPolicy.shouldNotify(item.category, settings) else { return }
        let key = "\(item.category.rawValue)|\(item.projectID?.uuidString ?? "-")|\(item.title)"
        if NotificationThrottle.shouldSuppress(key: key, now: item.date, last: lastNotified[key],
                                               window: NotificationThrottle.defaultWindow) { return }
        lastNotified[key] = item.date
        Notifier.shared.post(item)
        // Mirror the same (policy-passed, throttled) notification to an external webhook if one is
        // configured — Slack / Discord / any incoming webhook. Best-effort, off the main actor.
        if !settings.notifyWebhookURL.isEmpty {
            WebhookNotifier.post(urlString: settings.notifyWebhookURL, title: item.title, body: item.body)
        }
    }

    /// Notification action: relaunch the project's server and bring the window forward.
    func restartFromNotification(projectID: UUID?) {
        bringMainWindowToFront()
        guard let id = projectID, let p = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = id
        sessions[id]?.stop()
        launch(p)
    }

    /// Notification action: focus the app on the related project (or its build log / the pressure tab).
    func focusFromNotification(projectID: UUID?, showLogs: Bool) {
        bringMainWindowToFront()
        guard let id = projectID else {
            selectedTerminalID = "pressure"   // machine-wide (pressure) events
            return
        }
        // The project may have been removed since this notification fired (its entry lingers in the
        // feed). Selecting a dead id leaves the sidebar List with a selection that has no backing row,
        // which SwiftUI renders as a stale, un-removable "ghost" row — so ignore it. Mirrors the
        // existence guard in `restartFromNotification`.
        guard projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        selectedTerminalID = showLogs ? "b:\(id)" : "s:\(id)"
    }

    /// Activate the app and bring the single main window to the front (no SwiftUI openWindow here).
    /// Internal (not private) so the quota HUD's detached menu — which has no SwiftUI scene
    /// `openWindow` — can open the main window too.
    func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
    }

    /// Physical RAM in whole GB — the ceiling for any injected heap.
    var systemRAMGB: Int { max(1, Int((systemSampler.totalMem / 1_073_741_824).rounded())) }

    /// The dev-server heap (GB) that will actually be injected for `project`, capped at this machine's RAM.
    func effectiveMemoryGB(for project: Project) -> Int { project.effectiveMemoryGB(systemGB: systemRAMGB) }

    /// The build heap (GB) for `project` (independent from the dev server), capped at physical RAM.
    func effectiveBuildMemoryGB(for project: Project) -> Int { project.effectiveBuildMemoryGB(systemGB: systemRAMGB) }

    // Project CRUD + per-project settings live in AppState+Projects.swift (addProject, removeProject,
    // setMemoryGB/…, setPackageManager, …), all funneled through a single `mutate(_:_:)` helper.

    /// Launch (or no-op if already running) the supervised server for `project`, and select its
    /// tab in the global terminal. Idempotent; other projects' servers are left alone.
    func launch(_ project: Project) {
        selectedTerminalID = "s:\(project.id)"
        if let existing = sessions[project.id], existing.state.isActive { return }
        stopSiblings(of: "dev", for: project)   // only one of dev/build/preview runs per project
        let session = DevSession(project: project)
        session.onEvent = { [weak self] event in
            self?.route(NotificationPolicy.make(from: event, projectID: project.id))
        }
        // Persist the heap level the OOM autoscaler learns (AUTO mode), so the next launch starts
        // there instead of replaying 4→6→8 — and as the floor the shared-memory budget respects.
        session.onHeapEscalated = { [weak self] gb in self?.recordHeapEscalation(gb, for: project.id) }
        sessions[project.id] = session
        let heapGB = launchHeapGB(for: project, preview: false)
        session.start(memoryGB: heapGB, reservedPorts: reservedPorts(excluding: project.id))
        warnLowMemory(heapGB: heapGB, name: project.name, projectID: project.id)
    }

    /// Ports every OTHER active supervised session (dev server or preview) is currently using or
    /// about to bind — so a project with no explicit port override doesn't have to guess and collide
    /// with a sibling the way each project's own framework fallback does in isolation. See
    /// `DevSession.start(memoryGB:reservedPorts:)`.
    private func reservedPorts(excluding projectID: Project.ID) -> Set<Int> {
        let active = Array(sessions.values) + Array(previews.values)
        return Set(active.filter { $0.project.id != projectID && $0.state.isActive }
                          .compactMap(\.effectivePort))
    }

    /// Warn — never block (per the user's chosen behaviour) — when starting a process that will
    /// claim `heapGB` risks heavy swapping on this RAM-constrained Mac. Posts a passive `.pressure`
    /// notification (feed + history + a silent banner if that category is on); the server still
    /// starts. No-op when there's enough headroom. See `MemoryGuard.launchWarning`.
    ///
    /// When other servers are running, the banner carries a "Stop Other Servers" button — the one
    /// action that actually makes room — which keeps this project and stops the rest.
    private func warnLowMemory(heapGB: Int, name: String, projectID: Project.ID) {
        guard let msg = MemoryGuard.launchWarning(
            heapGB: heapGB, memUsed: systemSampler.systemMemUsed, memTotal: systemSampler.totalMem,
            swapUsed: systemSampler.systemSwapUsed, swapTotal: systemSampler.systemSwapTotal)
        else { return }
        let keep = projects.first { $0.id == projectID }
        let others = otherLiveServerCount(keeping: keep)
        route(NotificationItem(
            title: "Low memory — starting \(name)",
            body: others > 0 ? msg + " \(others) other server\(others == 1 ? " is" : "s are") running." : msg,
            category: .pressure, severity: .passive, projectID: projectID,
            action: others > 0 ? .freeMemory : .none))
    }

    /// Edge-triggered high-swap warning: fires ONCE when system swap climbs past the threshold, and
    /// re-arms only after it drops back down (hysteresis) — so a slow swap creep is surfaced before it
    /// freezes the Mac, without spamming. Distinct from the stuck-machine pressure alert. Called from
    /// the 30 s tick. See `MemoryGuard.swapCrossing`.
    @ObservationIgnored private var swapWarned = false
    /// Per runner (`"dev:<id>"` / `"preview:<id>"`): when a connection to it was last seen. Feeds idle
    /// auto-stop alongside launch time and log output — see `checkIdleServers`.
    @ObservationIgnored var lastConnectionAt: [String: Date] = [:]
    /// An idle check is scanning sockets off the main actor; the next tick skips instead of piling up.
    @ObservationIgnored var idleCheckInFlight = false
    private func checkSwapPressure() {
        let r = MemoryGuard.swapCrossing(swapPercent: systemSampler.systemSwapPercent, wasWarned: swapWarned)
        swapWarned = r.warned
        guard r.warn else { return }
        let pct = Int(systemSampler.systemSwapPercent)
        route(NotificationItem(
            title: "Swap \(pct)% full",
            body: "The Mac is leaning on swap. Close idle projects or heavy apps before starting more servers, or it may start to stutter.",
            category: .pressure, severity: .passive, projectID: nil, action: .open))
    }

    /// Pids of external (unsupervised) dev servers/builds we've already alerted about, so each is
    /// announced once — not every 30s tick. Pruned as processes exit (a reused pid can alert again).
    @ObservationIgnored private var alertedExternalPids: Set<Int32> = []

    /// Safety net for the "no unsupervised launches" rule the Claude hook enforces at the source. The
    /// hook only sees Claude Code's own Bash calls — a server/build started from a plain terminal, a
    /// script, an IDE task (or with the hook uninstalled) slips past it. The sampler still identifies
    /// those (isExternalDev/isExternalBuild); here we announce each new one once so nothing runs
    /// outside Owl Monitor unnoticed.
    private func checkExternalProcesses() {
        let external = systemSampler.processes.filter { $0.id > 0 && ($0.isExternalDev || $0.isExternalBuild) }
        alertedExternalPids.formIntersection(Set(external.map(\.id)))   // forget the ones that have exited
        for row in external where !alertedExternalPids.contains(row.id) {
            alertedExternalPids.insert(row.id)
            route(NotificationPolicy.externalProcessDetected(name: row.name, isBuild: row.isExternalBuild))
            AppLog.shared.event("Detected unsupervised \(row.isExternalBuild ? "build" : "dev server"): \(row.name) (pid \(row.id))")
        }
    }

    /// Stop the supervised server for one project.
    func stop(_ project: Project) { sessions[project.id]?.stop() }

    /// Dev, build and preview for one project are mutually exclusive — launching one stops the other
    /// two (they read "Stopped"). Workers are independent and never touched here.
    func stopSiblings(of kind: String, for project: Project) {
        if kind != "dev"     { sessions[project.id]?.stop() }
        if kind != "build"   { builds[project.id]?.stop() }
        if kind != "preview" { previews[project.id]?.stop() }
    }

    /// Stop every supervised server (pressure relief / Doctor "stop dev servers").
    func stopAllSessions() { for s in sessions.values { s.stop() } }

    // MARK: - Memory relief

    /// Stop every supervised server (dev and preview) except `keep`'s — the explicit "I'm only
    /// working on this one" way to hand RAM back. A user-level app can't make macOS drop its caches
    /// (`purge` and `memory_pressure -S` both need root), so stopping processes is the one real lever,
    /// and this is the pull that frees the most at once. Returns how many servers were stopped and
    /// roughly how much they held: their trees' physical footprint at the last 1 s sample.
    @discardableResult
    func stopOtherServers(keeping keep: Project?) -> (count: Int, bytes: Double) {
        var count = 0, bytes = 0.0
        for runner in Array(sessions.values) + Array(previews.values)
        where runner.state.isActive && runner.project.id != keep?.id {
            bytes += runner.history.last?.treeMem ?? 0
            runner.stop()
            count += 1
        }
        guard count > 0 else { return (0, 0) }
        let mb = bytes / 1_048_576
        let freed = mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
        route(NotificationItem(
            title: "Stopped \(count) server\(count == 1 ? "" : "s")",
            body: "Freed about \(freed) of memory" + (keep.map { " — \($0.name) kept running." } ?? "."),
            category: .pressure, severity: .passive, projectID: nil, action: .none))
        AppLog.shared.event("Memory relief: stopped \(count) server(s), ~\(Int(mb)) MB")
        return (count, bytes)
    }

    /// How many servers `stopOtherServers(keeping:)` would stop right now (drives its menu item).
    func otherLiveServerCount(keeping keep: Project?) -> Int {
        (Array(sessions.values) + Array(previews.values))
            .filter { $0.state.isActive && $0.project.id != keep?.id }.count
    }

    // MARK: - Zombie servers

    /// `<id>:<kind>` of every runner that's live right now — the tag a process must carry to count as
    /// supervised rather than orphaned (see OrphanReaper).
    private var supervisedRunnerKeys: Set<String> {
        var keys = Set<String>()
        for (id, s) in sessions where s.state.isActive { keys.insert(OrphanReaper.key(projectID: id, kind: "dev")) }
        for (id, p) in previews where p.state.isActive { keys.insert(OrphanReaper.key(projectID: id, kind: "preview")) }
        for (id, w) in workers where w.isRunning { keys.insert(OrphanReaper.key(projectID: id, kind: "worker")) }
        for (id, b) in builds where b.isRunning { keys.insert(OrphanReaper.key(projectID: id, kind: "build")) }
        return keys
    }

    /// Find and kill zombie servers (see OrphanReaper). The scan runs off the main actor.
    ///
    /// With `recover` — the launch-time pass — each dev server, preview and worker that was still
    /// running as a zombie is relaunched, supervised this time: after Owl Monitor quits unexpectedly,
    /// the servers you had up come back instead of lingering invisibly (holding their ports and RAM
    /// while the app called them "Idle"). A build is never re-run; a half-finished one is just
    /// cleaned up. Without `recover` — the periodic safety net — orphans are only removed.
    func sweepOrphans(recover: Bool) {
        let supervised = supervisedRunnerKeys
        Task { @MainActor [weak self] in
            let orphans = await Task.detached(priority: .utility) {
                OrphanReaper.scan(supervised: supervised)
            }.value
            guard let self, !orphans.isEmpty else { return }
            OrphanReaper.reap(orphans)

            let names = Set(orphans.map(\.projectID))
                .compactMap { id in self.projects.first { $0.id == id }?.name }.sorted()
            AppLog.shared.event("OrphanReaper: reaped \(orphans.count) orphaned tree(s) (\(names.joined(separator: ", "))), recover=\(recover)")

            guard recover else {
                self.route(NotificationItem(
                    title: "Cleaned up \(orphans.count) orphaned process\(orphans.count == 1 ? "" : "es")",
                    body: "Left running unsupervised by \(names.joined(separator: ", ")). Their ports and memory are free again.",
                    category: .pressure, severity: .passive, projectID: nil, action: .none))
                return
            }

            // Let the reaped trees actually die (the SIGKILL pass lands at ~2 s) so each server gets its
            // old port back rather than drifting to the next one past a dying zombie.
            try? await Task.sleep(for: .milliseconds(2500))
            var recovered: [String] = []
            for (id, kinds) in Dictionary(grouping: orphans, by: \.projectID).mapValues({ Set($0.map(\.kind)) }) {
                guard let project = self.projects.first(where: { $0.id == id }) else { continue }
                if kinds.contains("dev") { self.launch(project); recovered.append(project.name) }
                else if kinds.contains("preview") { self.startPreview(project); recovered.append("\(project.name) (preview)") }
                if kinds.contains("worker") { self.startWorker(project) }
            }
            guard !recovered.isEmpty else { return }
            self.route(NotificationItem(
                title: "Recovered \(recovered.count) server\(recovered.count == 1 ? "" : "s")",
                body: "Owl Monitor quit unexpectedly and left them running unsupervised. They're back under supervision: \(recovered.sorted().joined(separator: ", ")).",
                category: .recovery, severity: .passive, projectID: nil, action: .none))
        }
    }

    /// Reap every supervised server, build, worker and preview process tree on app quit, so nothing
    /// is left orphaned holding a port (they run in their own session via SETSID and would otherwise
    /// survive). Closes the IPC hub socket first. Runs synchronously since the process is terminating:
    /// enumerate each leader's FULL tree (session members + `setsid` descendants), SIGTERM all, a
    /// short grace, then SIGKILL. A force-kill of the app can't run this — the next launch's
    /// `reapLeftovers` covers it.
    func shutdown() {
        ipcServer.stop()
        sleepGuard.disable()
        let leaders = (sessions.values.map(\.pid) + builds.values.map(\.pid)
                       + workers.values.map(\.pid) + previews.values.map(\.pid)).filter { $0 > 0 }
        guard !leaders.isEmpty else { return }
        let pids = Array(Set(leaders.flatMap { ProcessTree.fullTree(of: $0) }))
        ProcessSupport.signalTree(pids, SIGTERM)
        usleep(400_000)
        ProcessSupport.signalTree(pids, SIGKILL)
    }

    /// Close a server tab in the global terminal: stop the dev server and drop it.
    func closeServer(id: Project.ID) {
        sessions[id]?.stop()
        sessions[id] = nil
    }

    /// Close a build tab in the global terminal: stop the build if running and drop it.
    func closeBuild(id: Project.ID) {
        builds[id]?.stop()
        builds[id] = nil
    }

    /// The supervised session for `project`, if any.
    func session(for project: Project) -> DevSession? { sessions[project.id] }

    // MARK: - Workers

    /// Launch (or no-op if already running, or the project has no worker) the background worker for
    /// `project`, and select its tab in the global terminal. Idempotent; injects the dev-server heap.
    func startWorker(_ project: Project) {
        guard project.workerCommand != nil else { return }
        selectedTerminalID = "w:\(project.id)"
        if let existing = workers[project.id], existing.isRunning { return }
        let worker = WorkerRunner(project: project)
        workers[project.id] = worker
        let heapGB = effectiveMemoryGB(for: project)
        worker.start(memoryGB: heapGB)
        warnLowMemory(heapGB: heapGB, name: "\(project.name) · worker", projectID: project.id)
    }

    /// Stop the background worker for one project.
    func stopWorker(_ project: Project) { workers[project.id]?.stop() }

    /// Close a worker tab in the global terminal: stop the worker if running and drop it.
    func closeWorker(id: Project.ID) {
        workers[id]?.stop()
        workers[id] = nil
    }

    /// The worker for `project`, if any.
    func worker(for project: Project) -> WorkerRunner? { workers[project.id] }

    // MARK: - Preview (serve the production build)

    /// Launch (or no-op) the production-build preview for `project` — a DevSession running the
    /// preview command, with the build heap (it serves the build). Idempotent; selects its tab.
    func startPreview(_ project: Project) {
        guard let cmd = project.previewCommand else { return }
        selectedTerminalID = "p:\(project.id)"
        if let existing = previews[project.id], existing.state.isActive { return }
        stopSiblings(of: "preview", for: project)   // only one of dev/build/preview runs per project
        let preview = DevSession(project: project, commandOverride: cmd)
        previews[project.id] = preview
        let heapGB = launchHeapGB(for: project, preview: true)
        preview.start(memoryGB: heapGB, reservedPorts: reservedPorts(excluding: project.id))
        warnLowMemory(heapGB: heapGB, name: "\(project.name) · preview", projectID: project.id)
    }

    /// Stop the preview server for one project.
    func stopPreview(_ project: Project) { previews[project.id]?.stop() }

    /// Close a preview tab in the global terminal: stop it and drop it.
    func closePreview(id: Project.ID) {
        previews[id]?.stop()
        previews[id] = nil
    }

    /// The preview server for `project`, if any.
    func preview(for project: Project) -> DevSession? { previews[project.id] }

    // Build orchestration (runBuild, runBuildAndWait + its pause/pressure/autoscale steps, build(for:))
    // lives in AppState+Builds.swift.

    // Doctor — READ-ONLY AI analyses. The generate/stop/reset + apply/applyAll methods and the
    // `advice`/`memoryAdvice`/… read shims live in AppState+Doctor.swift; each is backed by one of
    // these jobs (which own the guard/flag/Task lifecycle they used to duplicate). The Doctor's "Live
    // Scan" tab is instead backed by the `liveScan` manager below (it has its own progress lifecycle).
    let adviceJob = AsyncJob<ResourceAdvisor.Advice>()
    let memoryJob = AsyncJob<ResourceAdvisor.Advice>()
    /// Doctor "Project" tab: diagnose why the selected project's server/build failed.
    let projectJob = AsyncJob<ClaudeRunner.Report>()

    func persistSettings() { settingsStore.save(settings) }

    // Machine-pressure subsystem (kill suggestions, orphan auto-close, the "under pressure" tab) lives
    // in PressureManager, created in init(). These shims keep the view-facing API on AppState so the
    // views are unchanged.
    @ObservationIgnored private(set) var pressure: PressureManager!
    var systemUnderPressure: Bool { pressure.systemUnderPressure }
    var isEvaluatingPressure: Bool { pressure.isEvaluating }
    var killSuggestions: [ResourceAdvisor.Recommendation] { pressure.killSuggestions }
    func dismissPressure() { pressure.dismiss() }
    func killSuggestion(_ rec: ResourceAdvisor.Recommendation) { pressure.killSuggestion(rec) }

    // Doctor "Live Scan": watches the app + machine for a window, then a Claude report. Its own
    // progress/phase lifecycle lives in LiveScan; created in init() once `self` exists. View-facing
    // shims are in AppState+Doctor.swift.
    @ObservationIgnored private(set) var liveScan: LiveScan!

    /// BCP-47 language for AI reports — the chosen UI language, or the system locale's when "system",
    /// so a Live Scan report comes back in the language the user reads.
    var reportLanguageHint: String {
        settings.language == "system"
            ? (Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en")
            : settings.language
    }

    /// argv of a pid (joined), via KERN_PROCARGS2 — used for orphan dev-server detection.
    static func argv(of pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 8192)
        let n = Int(dm_proc_args(pid, &buf, 8192))
        return n > 0 ? String(cString: buf) : ""
    }

    /// SIGTERM a pid, escalating to SIGKILL if it's still alive shortly after.
    static func killPid(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }   // signal 0 = "are you still there?"
        }
    }

    /// Kill the process behind a table row (the hover ✕ button). A managed server or worker
    /// (synthetic id = -pid) is stopped through its supervisor; the aggregated build row stops every
    /// running build; any real process (external dev server, foreign helper) gets SIGTERM→SIGKILL.
    func killProcessRow(_ row: ProcessRow) {
        if row.isBuild {
            for b in builds.values where b.isRunning { b.stop() }
        } else if row.isWorker {
            workers.values.first { $0.pid == -row.id }?.stop()
        } else if row.isDevServer {
            sessions.values.first { $0.pid == -row.id }?.stop()
        } else if row.id > 0 {
            Self.killPid(row.id)
        }
    }

    func persist() {
        store.save(projects)
    }
}
