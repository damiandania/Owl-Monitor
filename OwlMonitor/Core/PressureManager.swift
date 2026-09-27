import Foundation
import Observation
import Darwin

/// Owns the machine-pressure subsystem: the "system under pressure" state, the one-shot auto-close of
/// orphaned dev processes, and the kill suggestions (instant heuristic, refined by Haiku) shown in
/// the yellow pressure tab. Split out of AppState; holds an `unowned` back-reference for the bits
/// that touch sessions, notifications and the selected tab — AppState owns this manager, so the
/// reference never dangles.
@MainActor
@Observable
final class PressureManager {
    /// Pressure-triggered kill suggestions: when the machine is stuck, a fast Haiku eval proposes
    /// processes to kill, shown above the server config with a red skull button.
    private(set) var killSuggestions: [ResourceAdvisor.Recommendation] = []
    private(set) var isEvaluating = false
    /// Set when the user closes (✕) the pressure tab — hides it until the machine recovers and the
    /// pressure re-triggers, so a manual dismiss isn't undone every refresh.
    private(set) var dismissed = false
    /// True for the duration of one stuck episode — so the "under pressure" notification fires once
    /// (not every refresh) and "recovered" only fires if we actually warned.
    @ObservationIgnored private var notified = false
    /// When Claude last refined the kill suggestions. A refinement spawns a whole `claude -p` — a
    /// node runtime of 100+ MB plus an API call — which is exactly what a machine under memory
    /// pressure can't spare, and the build's pressure watch used to trigger one every few seconds for
    /// the entire build. Claude now weighs in at most once per `refinementInterval`.
    @ObservationIgnored private var lastRefinement = Date.distantPast
    private static let refinementInterval: TimeInterval = 180

    @ObservationIgnored private unowned let app: AppState
    private var sampler: SystemSampler { app.systemSampler }

    init(app: AppState) { self.app = app }

    /// True while the machine is stuck / being evaluated / has kill suggestions — drives the yellow
    /// "System pressure" tab in the global terminal.
    var systemUnderPressure: Bool {
        if dismissed { return false }
        return isEvaluating || !killSuggestions.isEmpty || sampler.pressure == .stuck
    }

    /// User closed the pressure tab — clear it and keep it hidden until pressure re-triggers.
    func dismiss() {
        dismissed = true
        killSuggestions.removeAll()
    }

    /// Runs every ~1 min while a pressure tab is/was showing: prunes suggestions whose process has
    /// exited, clears everything once the machine recovers (so the tab disappears), and otherwise
    /// refreshes the suggestions while still stuck — without stealing the user's tab selection.
    func tick() {
        // Drop suggestions whose process is gone (signal 0 = "are you still there?").
        if !killSuggestions.isEmpty {
            killSuggestions.removeAll { $0.id > 0 && kill($0.id, 0) != 0 }
        }
        if sampler.pressure == .stuck {
            // Refresh the SUGGESTIONS only — do NOT re-run the orphan auto-close every tick.
            if !dismissed { refreshKillSuggestions() }
        } else {
            // Recovered: notify (if we warned), clear suggestions, and re-arm for the next event.
            if notified {
                app.route(NotificationPolicy.pressureCleared())
                notified = false
            }
            killSuggestions.removeAll()
            dismissed = false
        }
    }

    /// Called once on a genuine normal→stuck transition: focuses the pressure tab, auto-closes
    /// orphaned dev processes (one-shot), then computes the kill suggestions.
    func evaluate(focusTab: Bool = true) {
        if focusTab {
            dismissed = false                   // a fresh pressure event un-dismisses the tab
            app.selectedTerminalID = "pressure" // focus it so the suggestions are seen
            if !notified {                      // once per stuck episode
                notified = true
                app.route(NotificationPolicy.machineUnderPressure(reason: sampler.pressureReason))
            }
        }
        autoCloseOrphans()
        refreshKillSuggestions()
    }

    /// Every managed session's leader pid and its whole tree — never auto-close any of these, even a
    /// server still launching (whose tree isn't enumerable yet, so it isn't aggregated out and would
    /// otherwise look like an orphan dev server and get SIGKILLed mid-launch).
    private var managedPids: Set<Int32> {
        // Builds and workers too: a build is exactly what drives a machine into pressure, and it used
        // to be left out — only a "build" token in its argv kept its processes from looking orphaned.
        let leaders = app.sessions.values.map(\.pid) + app.previews.values.map(\.pid)
            + app.builds.values.map(\.pid) + app.workers.values.map(\.pid)
        return Set(leaders.flatMap { [$0] + ProcessTree.sessionMembers(of: $0) }.filter { $0 > 0 })
    }

    /// Whether `pid` carries Owl Monitor's ownership tag — i.e. it's one of OUR trees. Those are never
    /// this heuristic's business: a supervised one must be left alone, and an orphaned one is
    /// OrphanReaper's (which knows exactly what it was, and can bring it back).
    private static func isOwnedByUs(_ pid: Int32) -> Bool {
        var value = [CChar](repeating: 0, count: 128)
        return dm_proc_env_value(pid, ProcessSupport.ownershipKey, &value, Int32(value.count)) > 0
    }

    /// Auto-close ORPHANED dev processes — a dev server (by its binary in argv) that isn't part of a
    /// managed session. Managed servers (incl. one still launching), editor helpers and protected
    /// processes are excluded; what was closed is notified. (Off-switchable.)
    private func autoCloseOrphans() {
        guard app.settings.autoCloseOrphans else { return }
        let managed = managedPids
        let orphans = sampler.processes.filter { row in
            row.id > 0
                && !managed.contains(row.id)
                && !row.name.localizedCaseInsensitiveContains("Helper")
                && !ResourceAdvisor.isProtected(row.name)
                && ResourceAdvisor.looksLikeDevServer(argv: AppState.argv(of: row.id))
                && !Self.isOwnedByUs(row.id)
        }
        guard !orphans.isEmpty else { return }
        orphans.forEach { AppState.killPid($0.id) }
        let names = orphans.map(\.name).joined(separator: ", ")
        app.route(NotificationPolicy.orphansClosed(count: orphans.count, names: names))
        AppLog.shared.event("Pressure: auto-closed \(orphans.count) orphan(s): \(names)")
    }

    /// (Re)compute the kill suggestions: heuristic instantly, refined by Haiku. Managed servers are
    /// kept in the snapshot so a runaway one can be suggested by name. Safe to call on a refresh.
    func refreshKillSuggestions() {
        guard !isEvaluating else { return }
        isEvaluating = true
        let s = sampler
        let procs: [ResourceAdvisor.Proc] = s.processes
            .map { .init(pid: $0.id, name: $0.name, cpuPerCore: $0.cpuPerCore,
                         memMB: $0.memBytes / 1_048_576, managedDev: $0.isDevServer) }
        killSuggestions = ResourceAdvisor.heuristicKills(procs: procs)
        // The instant heuristic above refreshes every time; Claude's refinement only every few
        // minutes (see `refinementInterval`).
        guard Date().timeIntervalSince(lastRefinement) >= Self.refinementInterval else {
            isEvaluating = false
            return
        }
        lastRefinement = Date()
        let cpu = s.systemCPU, mem = s.systemMemPercent, swap = s.systemSwapPercent, cores = s.coreCount
        let model = app.settings.analysisModel
        Task { [weak self] in
            let recs = await ResourceAdvisor.pressureKills(
                systemCPU: cpu, systemMemPercent: mem, systemSwapPercent: swap,
                coreCount: cores, procs: procs, model: model)
            if !recs.isEmpty { self?.killSuggestions = recs }
            self?.isEvaluating = false
        }
    }

    /// Kill a suggested process (red-skull button). The dev-server tree is stopped via the
    /// supervisor; a foreign process gets SIGTERM, escalating to SIGKILL if still alive.
    func killSuggestion(_ rec: ResourceAdvisor.Recommendation) {
        if rec.action == .stopDevServer || rec.id == -1 {
            // The suggestion's id is the server's synthetic id (-pid) — stop THAT server; if it
            // doesn't map to a live session, fall back to stopping all.
            if let s = app.sessions.values.first(where: { $0.pid == -rec.id }) { s.stop() }
            else { app.stopAllSessions() }
        } else if rec.id > 0 {
            AppState.killPid(rec.id)
        }
        killSuggestions.removeAll { $0.id == rec.id }
    }
}
