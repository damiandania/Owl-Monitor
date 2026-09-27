import Foundation

/// Memory policy for a RAM-constrained Mac: how big a heap each launch gets when several servers
/// share the machine, and stopping the servers nobody is using.
extension AppState {
    // MARK: - Heap budget

    /// The heap (GB) to launch `project`'s dev server (or, with `preview`, its production preview)
    /// with. Manual heaps and a disabled budget are used as-is; in auto mode the learned level is
    /// capped at an even share of the RAM left after macOS, counting the servers already running
    /// (see `MemoryGuard.budgetedHeapGB`), and never cut below what the project has proven it needs.
    func launchHeapGB(for project: Project, preview: Bool) -> Int {
        let learned = preview ? effectiveBuildMemoryGB(for: project) : effectiveMemoryGB(for: project)
        let auto = preview ? project.buildMemoryAuto : project.memoryAuto
        guard settings.shareHeapBudget, auto else { return learned }
        let others = otherLiveServerCount(keeping: project)
        let gb = MemoryGuard.budgetedHeapGB(
            learnedGB: learned,
            floorGB: preview ? project.previewHeapFloorGB : project.devHeapFloorGB,
            systemGB: systemRAMGB, otherServers: others)
        if gb < learned {
            AppLog.shared.event("Heap budget: \(project.name)\(preview ? " preview" : "") gets \(gb) GB (learned \(learned) GB) — \(others) other server(s) in \(systemRAMGB) GB RAM")
        }
        return gb
    }

    /// Notification action on a low-memory warning: stop every OTHER server, keeping `projectID`'s.
    func stopOtherServersFromNotification(projectID: UUID?) {
        stopOtherServers(keeping: projectID.flatMap { id in projects.first { $0.id == id } })
    }

    // MARK: - Idle auto-stop

    /// Stop dev servers and previews nobody has used for `settings.idleStopMinutes` (off at 0).
    ///
    /// "Used" is any of: a browser tab connected (its page load or HMR websocket shows up as a
    /// connection the server accepted — outbound ones, to a database or API, don't count, nor do
    /// its own processes talking to each other or Owl Monitor's health probe), output
    /// in the log (a request, a rebuild after a file save), or the launch itself. Connections are
    /// sampled on the 30 s tick, so a request that comes and goes between samples is only seen
    /// through the output it causes. The socket scan runs off the main actor.
    func checkIdleServers() {
        let minutes = settings.idleStopMinutes
        guard minutes > 0, !idleCheckInFlight else { return }
        var runners: [(key: String, session: DevSession)] = []
        for (id, s) in sessions { runners.append(("dev:\(id)", s)) }
        for (id, p) in previews { runners.append(("preview:\(id)", p)) }
        runners = runners.filter {
            switch $0.session.state {
            case .running, .degraded: return $0.session.pid > 0
            default: return false
            }
        }
        guard !runners.isEmpty else { return }
        let targets = runners.map { (key: $0.key, pid: $0.session.pid) }

        idleCheckInFlight = true
        Task { @MainActor [weak self] in
            let inbound = await Task.detached(priority: .utility) { () -> [String: Int] in
                // Our own health probe holds a keep-alive connection to every server — that's us,
                // not a user — and a tree's processes may talk to each other over loopback, so only
                // connections from outside both count.
                let me = getpid()
                var counts: [String: Int] = [:]
                for t in targets {
                    let tree = ProcessTree.fullTree(of: t.pid)
                    counts[t.key] = Int(tree.withUnsafeBufferPointer {
                        dm_tree_inbound_count($0.baseAddress, Int32($0.count), me)
                    })
                }
                return counts
            }.value
            guard let self else { return }
            self.idleCheckInFlight = false
            let now = Date()
            for (key, session) in runners {
                // Re-check: it may have been stopped or relaunched while the scan ran.
                guard session.state.isActive, targets.contains(where: { $0.key == key && $0.pid == session.pid }) else { continue }
                if (inbound[key] ?? 0) > 0 { self.lastConnectionAt[key] = now }
                let lastActivity = [session.startedAt, session.lastOutputAt, self.lastConnectionAt[key]]
                    .compactMap { $0 }.max() ?? now
                guard MemoryGuard.isIdle(lastActivity: lastActivity, now: now, minutes: self.settings.idleStopMinutes)
                else { continue }
                self.stopIdle(session, key: key, minutes: self.settings.idleStopMinutes)
            }
        }
    }

    private func stopIdle(_ session: DevSession, key: String, minutes: Int) {
        let isPreview = key.hasPrefix("preview:")
        let project = session.project
        let mb = (session.history.last?.treeMem ?? 0) / 1_048_576
        let freed = mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
        session.stop()
        lastConnectionAt[key] = nil
        let span = minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min"
        AppLog.shared.event("Idle auto-stop: \(project.name)\(isPreview ? " preview" : "") after \(span) — ~\(Int(mb)) MB")
        route(NotificationItem(
            title: "Stopped idle \(project.name)\(isPreview ? " preview" : "")",
            body: "No browser tab or output for \(span) — freed about \(freed). "
                + (isPreview ? "Start it again from Owl Monitor." : "Restart brings it back."),
            category: .pressure, severity: .passive, projectID: project.id,
            action: isPreview ? .open : .restartOpen))
    }
}
