import Foundation

/// Project list CRUD and per-project settings. Every mutation funnels through `mutate(_:_:)` so the
/// "find the project, change one field, persist" pattern lives in exactly one place.
extension AppState {

    /// Add (or focus, if already present) a project. Returns the project, or `nil` when `path` is not
    /// a launchable project folder — in which case nothing is created or persisted.
    @discardableResult
    func addProject(path: String, groupRoot: String? = nil) -> Project? {
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectID = existing.id
            return existing
        }
        guard Detector.isProject(path: path) else { return nil }
        let d = Detector.detect(path: path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let project = Project(
            name: name,
            path: path,
            groupRoot: groupRoot,
            packageManager: d.packageManager,
            framework: d.framework,
            devCommand: d.devCommand,
            buildCommand: d.buildCommand,
            workerCommand: d.workerCommand,
            previewCommand: d.previewCommand,
            memoryGB: settings.defaultMemoryGB,   // new projects inherit the default-heap setting
            port: d.port
        )
        projects.append(project)
        selectedProjectID = project.id
        persist()
        return project
    }

    /// Add every project found under `root`: the folder itself when it's a project, otherwise a
    /// bounded scan of its subfolders (skipping dependency/output dirs, and never descending INTO a
    /// folder already identified as a project). De-dupes via `addProject`; selects the first found.
    /// Returns the projects added or re-focused. Lets the user drop a whole parent folder (e.g. `~/Dev`)
    /// and pick up all its projects at once.
    @discardableResult
    func addProjects(under root: String, maxDepth: Int = 3) -> [Project] {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", "dist", "build", ".next", ".nuxt", ".output",
                                 "vendor", "target", "Pods", ".svelte-kit", "coverage", ".turbo", ".git"]
        var found: [String] = []
        func scan(_ dir: String, _ depth: Int) {
            if Detector.isProject(path: dir) { found.append(dir); return }  // a project — don't go inside it
            guard depth < maxDepth, let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in entries.sorted() where !name.hasPrefix(".") && !skip.contains(name) {
                let child = dir + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                scan(child, depth + 1)
            }
        }
        scan(root, 0)
        // Group everything found under the folder the user actually dropped — but only when we scanned
        // INTO it. If `root` is itself the project, there's nothing to cluster: leave groupRoot nil so
        // the sidebar groups it by its parent like a normal single add.
        let added = found.compactMap { addProject(path: $0, groupRoot: $0 == root ? nil : root) }
        if let first = added.first { selectedProjectID = first.id }
        return added
    }

    /// Backfill / refresh each project's `workerCommand` and `previewCommand` from its package.json on
    /// launch — so a project saved before those existed gains them when the script is present, and
    /// they stay in sync if scripts are later added or removed. Persists only on an actual change.
    func refreshWorkerCommands() {
        var changed = false
        for i in projects.indices {
            let c = Detector.commands(path: projects[i].path, packageManager: projects[i].packageManager)
            if projects[i].workerCommand != c.worker { projects[i].workerCommand = c.worker; changed = true }
            if projects[i].previewCommand != c.preview { projects[i].previewCommand = c.preview; changed = true }
        }
        if changed { persist() }
    }

    func removeProject(_ id: Project.ID) {
        sessions[id]?.stop(); sessions[id] = nil
        builds[id]?.stop(); builds[id] = nil
        workers[id]?.stop(); workers[id] = nil
        projects.removeAll { $0.id == id }
        // Drop the removed project's entries from the in-app feed so no dead notification lingers
        // (clicking one would try to focus a project that no longer exists). History on disk is kept.
        recentNotifications.removeAll { $0.projectID == id }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        persist()
    }

    /// Find the project by id, apply `body` to it, and persist. The single funnel for every
    /// per-project field change below.
    private func mutate(_ id: Project.ID, _ body: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        body(&projects[i])
        persist()
    }

    func setMemoryGB(_ gb: Int, for id: Project.ID) { mutate(id) { $0.memoryGB = max(1, gb) } }
    func setMemoryAuto(_ auto: Bool, for id: Project.ID) { mutate(id) { $0.memoryAuto = auto } }
    func setPort(_ port: Int?, for id: Project.ID) { mutate(id) { $0.port = (port ?? 0) > 0 ? port : nil } }
    /// Set the health-probe path (nil/empty = "/"). Applies on the next launch.
    func setHealthPath(_ path: String?, for id: Project.ID) {
        mutate(id) { p in
            let t = path?.trimmingCharacters(in: .whitespaces)
            p.healthPath = (t?.isEmpty == false && t != "/") ? t : nil
        }
    }
    func setBuildMemoryGB(_ gb: Int, for id: Project.ID) { mutate(id) { $0.buildMemoryGB = max(1, gb) } }
    func setBuildMemoryAuto(_ auto: Bool, for id: Project.ID) { mutate(id) { $0.buildMemoryAuto = auto } }

    /// Persist the dev-server heap level learned by the OOM autoscaler (AUTO mode), so the next
    /// launch starts there instead of replaying 4→6→8.
    func setAutoHeapGB(_ gb: Int, for id: Project.ID) { mutate(id) { $0.autoHeapGB = gb } }

    /// The OOM autoscaler just relaunched `id` with a `gb` heap: persist it as the learned level AND as
    /// the floor, so the shared-memory budget never squeezes the project back under a heap it already
    /// ran out of memory at (see `launchHeapGB`).
    func recordHeapEscalation(_ gb: Int, for id: Project.ID) {
        mutate(id) {
            $0.autoHeapGB = max($0.autoHeapGB, gb)
            $0.heapFloorGB = max($0.heapFloorGB ?? 0, gb)
        }
    }

    /// Persist the build heap level learned by the OOM autoscaler (AUTO mode).
    func setBuildAutoHeapGB(_ gb: Int, for id: Project.ID) { mutate(id) { $0.buildAutoHeapGB = gb } }

    /// Replace the project's user-defined environment variables (injected on the next launch of any
    /// supervised run). Kept verbatim/ordered — trimming/skip-empty happens at injection time.
    func setEnv(_ env: [Project.EnvVar], for id: Project.ID) { mutate(id) { $0.env = env } }

    /// Persist the last successful build's wall-clock duration — the ETA for the next build's
    /// progress bar. Survives relaunch/reinstall (it rides along in projects.json).
    func setLastBuildSeconds(_ seconds: TimeInterval, for id: Project.ID) { mutate(id) { $0.lastBuildSeconds = seconds } }

    /// Manually override the package manager → regenerate the dev/build commands for it.
    func setPackageManager(_ pm: PackageManager, for id: Project.ID) {
        mutate(id) {
            let c = Detector.commands(path: $0.path, packageManager: pm)
            $0.packageManager = pm
            $0.devCommand = c.dev
            $0.buildCommand = c.build
            $0.workerCommand = c.worker
            $0.previewCommand = c.preview
        }
    }

    /// Toggle package-manager auto. Turning it back on re-detects and restores the commands.
    func setPackageManagerAuto(_ auto: Bool, for id: Project.ID) {
        mutate(id) {
            if auto {
                let d = Detector.detect(path: $0.path)
                $0.packageManager = d.packageManager
                $0.devCommand = d.devCommand
                $0.buildCommand = d.buildCommand
                $0.workerCommand = d.workerCommand
                $0.previewCommand = d.previewCommand
            }
            $0.packageManagerAuto = auto
        }
    }
}
