import SwiftUI

/// A single project run-control, described uniformly so every surface — the dashboard pills, the
/// menu-bar rows and the terminal tabs — renders it the same way. The list comes from one place
/// (`AppState.runControls(for:)`), so adding a new supervised process type there makes it appear
/// everywhere automatically.
struct RunControl: Identifiable {
    /// Stable per-kind id ("dev", "worker", "build", "preview").
    let kind: String
    /// Left-to-right ordering within a project (dev, worker, build, preview).
    let rank: Int
    let projectID: Project.ID
    let projectName: String
    let title: String
    /// SF Symbol for the terminal tab / menu row.
    let icon: String
    /// Terminal-selection id, e.g. "s:<projectID>" / "w:" / "b:" / "p:".
    let tabID: String
    let status: RunStatus
    /// Lazy accessor for the runner's log. A closure, NOT the array: `logLines` is appended to on
    /// every output line, so embedding the array here would make every status surface (menu-bar
    /// icon, tab strip, dashboard pills) observe it and re-render per line during chatty output.
    /// Only the pane that actually renders the log should call this.
    let logLines: () -> [String]
    let startedAt: Date?
    /// For the build control: seconds the last successful build took (the progress-bar ETA); nil
    /// for the others, which use a plain uptime counter.
    let buildETA: TimeInterval?
    /// Whether a backing runner instance exists — drives whether a terminal tab / menu row shows.
    let isLive: Bool
    /// Port the server is bound to (dev / preview); nil for a worker or build.
    let port: Int?
    /// Package-manager name (npm / pnpm / yarn / bun / deno) — shown in the run-timer footer.
    let packageManager: String
    let onToggle: () -> Void
    let onClose: () -> Void

    var id: String { tabID }
    var isBuild: Bool { kind == "build" }
    /// The terminal-pane footer: a build-style elapsed+ETA bar, else a plain uptime counter (only
    /// while active).
    var timerMode: RunTimerBar.Mode? {
        guard let startedAt else { return nil }
        if isBuild {
            return status.isInProgress ? .build(since: startedAt, estimate: buildETA) : nil
        }
        return status.showsStop ? .uptime(since: startedAt, port: port, packageManager: packageManager) : nil
    }
}

extension AppState {
    /// THE single source of a project's run-controls. Add a new supervised process type here and it
    /// shows up automatically in the dashboard, the menu bar and the terminal.
    func runControls(for project: Project) -> [RunControl] {
        var out: [RunControl] = []

        // Dev server — always present.
        out.append(serverControl(kind: "dev", rank: 0, title: "Dev", icon: "xserve",
            prefix: "s", running: "Running", session: sessions[project.id], project: project,
            toggle: { [weak self] active in active ? self?.stop(project) : self?.launch(project) },
            close: { [weak self] in self?.closeServer(id: project.id) }))

        // Worker.
        if project.workerCommand != nil {
            let w = workers[project.id]
            out.append(RunControl(
                kind: "worker", rank: 1, projectID: project.id, projectName: project.name,
                title: "Worker", icon: "gearshape.2.fill", tabID: "w:\(project.id)",
                status: workerStatus(w), logLines: { w?.logLines ?? [] }, startedAt: w?.startedAt,
                buildETA: nil, isLive: w != nil,
                port: nil, packageManager: project.packageManager.rawValue,
                onToggle: { [weak self] in (w?.isRunning == true) ? self?.stopWorker(project) : self?.startWorker(project) },
                onClose: { [weak self] in self?.closeWorker(id: project.id) }))
        }

        // Build.
        if project.buildCommand != nil {
            let b = builds[project.id]
            out.append(RunControl(
                kind: "build", rank: 2, projectID: project.id, projectName: project.name,
                title: "Build", icon: "hammer.fill", tabID: "b:\(project.id)",
                status: buildStatus(b), logLines: { b?.logLines ?? [] }, startedAt: b?.startedAt,
                buildETA: project.lastBuildSeconds, isLive: b != nil,
                port: nil, packageManager: project.packageManager.rawValue,
                onToggle: { [weak self] in (b?.isRunning == true) ? b?.stop() : self?.runBuild(project) },
                onClose: { [weak self] in self?.closeBuild(id: project.id) }))
        }

        // Preview (serve the production build) — reuses DevSession.
        if project.previewCommand != nil {
            out.append(serverControl(kind: "preview", rank: 3, title: "Preview", icon: "eye.fill",
                prefix: "p", running: "Serving", session: previews[project.id], project: project,
                toggle: { [weak self] active in active ? self?.stopPreview(project) : self?.startPreview(project) },
                close: { [weak self] in self?.closePreview(id: project.id) }))
        }

        return out
    }

    /// Build a control backed by a DevSession (the dev server and the preview both are one).
    private func serverControl(kind: String, rank: Int, title: String, icon: String, prefix: String,
                               running: String, session: DevSession?, project: Project,
                               toggle: @escaping (Bool) -> Void, close: @escaping () -> Void) -> RunControl {
        let active = session?.state.isActive ?? false
        return RunControl(
            kind: kind, rank: rank, projectID: project.id, projectName: project.name,
            title: title, icon: icon, tabID: "\(prefix):\(project.id)",
            status: sessionStatus(session, running: running, servingBuild: kind == "preview"),
            logLines: { session?.logLines ?? [] }, startedAt: session?.startedAt,
            buildETA: nil, isLive: session != nil,
            port: session?.effectivePort, packageManager: project.packageManager.rawValue,
            onToggle: { toggle(active) }, onClose: close)
    }

    // MARK: - Runner → RunStatus mappings (the one place each process type's UI status is defined)

    /// `servingBuild` — the preview serves a production BUILD rather than dev sources, so its "up"
    /// state gets its own status (magenta) instead of the dev server's green, and every surface that
    /// reads `RunStatus.color` picks that up automatically.
    private func sessionStatus(_ s: DevSession?, running: String, servingBuild: Bool) -> RunStatus {
        switch s?.state ?? .idle {
        case .idle:       return .idle
        case .launching:  return .starting("Launching…")
        case .recycling:  return .starting("Recycling…")
        case .degraded:   return .starting("Unresponsive")
        case .running:    return servingBuild ? .serving(running) : .running(running)
        case .stopped:    return .stopped
        case .failed:     return .failed(terminalError(s?.logLines))
        }
    }

    private func workerStatus(_ w: WorkerRunner?) -> RunStatus {
        guard let w else { return .idle }
        if w.isRunning { return .running("Running") }
        if w.didCrash { return .failed(terminalError(w.logLines)) }
        return w.lastExitCode != nil ? .stopped : .idle
    }

    private func buildStatus(_ b: BuildRunner?) -> RunStatus {
        guard let b else { return .idle }
        if b.isRunning { return .starting("Building…") }
        if b.wasStopped { return .stopped }          // user cancelled — not a failure
        switch b.result {
        case .some(0): return .done("Complete")
        case .some:    return .failed(terminalError(b.logLines))
        default:       return .idle
        }
    }

    /// The tail of a runner's terminal output (ANSI-stripped) — shown/copied in the error popover.
    private func terminalError(_ lines: [String]?) -> String {
        (lines ?? []).suffix(200).map(\.strippedANSI).joined(separator: "\n")
    }
}
