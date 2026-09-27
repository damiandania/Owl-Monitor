import Foundation

/// Build orchestration: run a project's build while pausing dev servers to free RAM, relieve memory
/// pressure during it, and autoscale the heap on OOM. `runBuildAndWait` reads as a short sequence of
/// named steps; each step is one helper below.
extension AppState {

    /// Build a project, **pausing its dev server while the build runs** to free RAM (relaunched
    /// after), adding a build tab to the global terminal and selecting it.
    func runBuild(_ project: Project) {
        guard builds[project.id]?.isRunning != true else { return }
        // Reuse the autoscaling build loop so a UI-triggered build also retries 4→6→8 on OOM. The
        // build tab follows each attempt as `builds[project.id]` is replaced.
        Task { @MainActor in _ = await runBuildAndWait(project) }
    }

    /// Build a project and WAIT for completion, returning the finished BuildRunner. Backs the
    /// synchronous `build` IPC command so the CLI can report exit code + output instead of
    /// returning immediately. Pauses the project's dev server while building (to free RAM) and
    /// relaunches it after.
    ///
    /// OOM autoscaler: starts at the build's effective heap and, in AUTO mode, retries with the next
    /// step (4→6→8) on an out-of-memory failure, persisting the learned level (`buildAutoHeapGB`) so
    /// the next build starts there. Returns the LAST BuildRunner (success, or the final failure).
    func runBuildAndWait(_ project: Project) async -> BuildRunner {
        selectedTerminalID = "b:\(project.id)"
        // Already building this project → attach to it and await the same completion.
        if let existing = builds[project.id], existing.isRunning {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let previous = existing.onFinish
                existing.onFinish = { success in
                    previous?(success)
                    cont.resume()
                }
            }
            return existing
        }

        // Only one of dev/build/preview runs per project — stop this project's dev/preview (they stay
        // Stopped, not relaunched). OTHER projects' servers are merely paused for RAM and relaunched.
        stopSiblings(of: "build", for: project)
        let pausedServerIDs = pauseActiveServersForBuild(buildName: project.name, excluding: project.id)
        defer { relaunchPausedServers(pausedServerIDs) }

        // RAM relief for the build — the whole point of this app on small Macs. (1) the other
        // projects' servers were stopped above, (2) surface the resource advisor so heavy
        // non-essential apps can be closed (user-confirmed), (3) keep relieving pressure during the
        // build so we act BEFORE the kernel jetsams it (SIGKILL) once swap fills up.
        //
        // There used to be a `purge` here too. It never worked: `/usr/sbin/purge` needs root and
        // exits with "Operation not permitted" for a normal app (so does `memory_pressure -S`) —
        // it only spawned a process that failed. A user-level app can't make macOS drop its caches;
        // the one real lever is stopping processes, which is what (1) and (2) do.
        pressure.evaluate(focusTab: false)
        let pressureWatch = startBuildPressureWatch()
        defer { pressureWatch.cancel() }

        return await autoscaleBuild(project)
    }

    /// The active build if it belongs to `project`, else nil.
    func build(for project: Project) -> BuildRunner? { builds[project.id] }

    // MARK: - Steps

    /// Pause every active dev server (not just this project's) so the build gets the most RAM — on a
    /// starved Mac even another project's server can drive the build into a kernel SIGKILL (not a
    /// clean V8 OOM), which fails it and defeats the autoscaler. Returns the ids to relaunch after.
    private func pauseActiveServersForBuild(buildName: String, excluding excludedID: Project.ID) -> [Project.ID] {
        let ids = sessions.compactMap { $0.key != excludedID && $0.value.state.isActive ? $0.key : nil }
        for id in ids { sessions[id]?.stop() }
        if !ids.isEmpty {
            AppLog.shared.event("Build \(buildName): paused \(ids.count) dev server(s) to free RAM")
        }
        return ids
    }

    /// Relaunch the servers paused for a build, deferred with a short settle delay and re-read from
    /// the store, so it doesn't race the just-paused sessions' state transitions (which left one Idle).
    private func relaunchPausedServers(_ ids: [Project.ID]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            for id in ids where self.sessions[id]?.state.isActive != true {
                if let p = self.projects.first(where: { $0.id == id }) { self.launch(p) }
            }
        }
    }

    /// Keep relieving memory pressure while a build runs: every 5s, if the machine is tight,
    /// re-evaluate (close unsupervised orphans, refresh the kill suggestions) so we act before the
    /// kernel jetsams the build once swap fills up. Claude's part of that is throttled inside
    /// PressureManager, so this loop no longer spawns a `claude -p` every few seconds.
    private func startBuildPressureWatch() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.systemSampler.systemMemPercent > 85 else { continue }
                self.pressure.evaluate(focusTab: false)
            }
        }
    }

    /// Run the build, retrying with the next heap step (4→6→8) on an OOM in AUTO mode and persisting
    /// the learned level. Returns the last BuildRunner (success, or the final failure).
    private func autoscaleBuild(_ project: Project) async -> BuildRunner {
        var heapGB = effectiveBuildMemoryGB(for: project)
        while true {
            let build = BuildRunner(project: project)
            build.onEvent = { [weak self] event in
                self?.route(NotificationPolicy.make(from: event, projectID: project.id))
            }
            builds[project.id] = build
            // Set onFinish BEFORE start() so the exit can't race ahead of our continuation.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                build.onFinish = { _ in cont.resume() }
                build.start(memoryGB: heapGB)
            }
            let code = build.result ?? -1
            // Remember a successful build's duration as the ETA for the next build's progress bar.
            if code == 0, let d = build.duration { setLastBuildSeconds(d, for: project.id) }
            let isAuto = projects.first(where: { $0.id == project.id })?.buildMemoryAuto ?? false
            guard code != 0, isAuto,
                  HeapScaling.looksLikeOOM(logLines: build.logLines, exitCode: code),
                  let next = HeapScaling.next(after: heapGB, systemGB: systemRAMGB)
            else { return build }
            setBuildAutoHeapGB(next, for: project.id)   // persist the learned level before retrying
            heapGB = next
            AppLog.shared.event("Build \(project.name) OOM (exit \(code)) — retrying with \(next) GB")
        }
    }
}
