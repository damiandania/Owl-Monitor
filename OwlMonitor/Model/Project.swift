import Foundation

/// JS/TS package manager, detected from the project's lockfile.
enum PackageManager: String, Codable, Sendable, CaseIterable {
    case npm, pnpm, yarn, bun, deno

    /// The run prefix for a script (e.g. `npm run`, `pnpm`).
    var runScriptPrefix: String {
        switch self {
        case .npm: return "npm run"
        case .pnpm: return "pnpm"
        case .yarn: return "yarn"
        case .bun: return "bun run"
        case .deno: return "deno task"
        }
    }
}

/// Detected web framework, drives the default dev command, port and ready-signal.
enum Framework: String, Codable, Sendable, CaseIterable {
    case nuxt, next, astro, sveltekit, remix, solid, angular, qwik, vite, express, node, unknown

    var displayName: String {
        switch self {
        case .nuxt: return "Nuxt"
        case .next: return "Next.js"
        case .astro: return "Astro"
        case .sveltekit: return "SvelteKit"
        case .remix: return "Remix"
        case .solid: return "SolidStart"
        case .angular: return "Angular"
        case .qwik: return "Qwik"
        case .vite: return "Vite"
        case .express: return "Express"
        case .node: return "Node"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .nuxt, .next, .astro, .sveltekit, .remix, .solid, .angular, .qwik, .vite: return "globe"
        case .express, .node: return "xserve"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// A supervised project. Persisted to Application Support.
struct Project: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Absolute path to the project root.
    var path: String
    /// The folder the user actually added, when this project was found by scanning INTO it (e.g.
    /// dropping `~/Dev/42` discovers projects nested at various depths). Drives sidebar grouping so
    /// every project found under one dropped root clusters under it. `nil` when the project's own
    /// folder was added directly — the sidebar then falls back to grouping by the immediate parent.
    var groupRoot: String?
    var packageManager: PackageManager
    var framework: Framework
    /// Optional override for the dev command; `nil` = auto-derived.
    var devCommand: String?
    /// Optional override for the build command; `nil` = auto-derived.
    var buildCommand: String?
    /// Long-running background worker command (e.g. a queue/job worker). `nil` = the project has no
    /// worker; non-nil makes the worker controls appear (mirrors `buildCommand`).
    var workerCommand: String?
    /// Command to serve the production build (`preview` / `start`). `nil` = none; non-nil makes the
    /// Preview control appear.
    var previewCommand: String?
    /// Heap size in GB injected as `--max-old-space-size` (used when `memoryAuto` is false).
    var memoryGB: Int
    /// When true, the heap follows the framework default instead of `memoryGB`.
    var memoryAuto: Bool
    /// Optional port override; `nil` = parse from stdout, fallback 3000 (i.e. "auto").
    var port: Int?
    /// Path the health probe requests; `nil`/empty = "/". Lets an API-only server whose "/" route
    /// hangs or is absent point the liveness check at a real route (e.g. "/health"). Any HTTP
    /// response (even 404) counts as alive — the probe measures liveness, not correctness.
    var healthPath: String?
    /// When true, the package manager / dev command follow detection instead of `packageManager`.
    var packageManagerAuto: Bool
    /// Dev-server heap (GB) used when `memoryAuto` is on: the level last learned by the OOM
    /// autoscaler — starts at 4, climbs 4→6→8 on OOM and is persisted — instead of a fixed
    /// framework default. The dev server and the build keep SEPARATE learned levels.
    var autoHeapGB: Int
    /// Build heap (GB) used when `buildMemoryAuto` is off — independent from the dev server's heap
    /// (a production build is usually heavier than the dev server).
    var buildMemoryGB: Int
    /// When true, the build heap follows the OOM autoscaler (`buildAutoHeapGB`) instead of `buildMemoryGB`.
    var buildMemoryAuto: Bool
    /// Build heap (GB) used when `buildMemoryAuto` is on: the level last learned by the build OOM
    /// autoscaler — starts at 4, climbs 4→6→8 on OOM, persisted.
    var buildAutoHeapGB: Int
    /// Wall-clock seconds the last successful build took — the ETA for the next build's progress bar.
    /// Learned and persisted (like `autoHeapGB`), so the bar shows an estimate immediately after a
    /// relaunch or reinstall instead of running blind until the session's first build finishes. `nil`
    /// until the first successful build.
    var lastBuildSeconds: TimeInterval?
    /// The smallest dev-server heap (GB) this project has PROVEN it needs: set whenever the OOM
    /// autoscaler escalates, so the shared-memory budget (`MemoryGuard.budgetedHeapGB`) never squeezes
    /// it back below a level it already ran out of memory at. nil until the first out-of-memory.
    var heapFloorGB: Int?
    /// User-defined environment variables injected (inline, `KEY='value'`) ahead of every supervised
    /// run — dev server, preview, build, and worker. Ordered so the editor list is stable. Empty by
    /// default; the app never sets these itself (it only manages PORT/NODE_OPTIONS/FORCE_COLOR).
    var env: [EnvVar]

    /// One `KEY=value` pair. Ordered (array, not dict) so the editor rows don't reshuffle.
    struct EnvVar: Codable, Hashable, Sendable, Identifiable {
        var id: UUID = UUID()
        var key: String
        var value: String
        enum CodingKeys: String, CodingKey { case key, value }   // id is ephemeral, not persisted
    }

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        groupRoot: String? = nil,
        packageManager: PackageManager = .npm,
        framework: Framework = .unknown,
        devCommand: String? = nil,
        buildCommand: String? = nil,
        workerCommand: String? = nil,
        previewCommand: String? = nil,
        memoryGB: Int = 4,
        memoryAuto: Bool = true,
        port: Int? = nil,
        healthPath: String? = nil,
        packageManagerAuto: Bool = true,
        autoHeapGB: Int = HeapScaling.firstGB,
        buildMemoryGB: Int = 4,
        buildMemoryAuto: Bool = true,
        buildAutoHeapGB: Int = HeapScaling.firstGB,
        lastBuildSeconds: TimeInterval? = nil,
        heapFloorGB: Int? = nil,
        env: [EnvVar] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.groupRoot = groupRoot
        self.packageManager = packageManager
        self.framework = framework
        self.devCommand = devCommand
        self.buildCommand = buildCommand
        self.workerCommand = workerCommand
        self.previewCommand = previewCommand
        self.memoryGB = memoryGB
        self.memoryAuto = memoryAuto
        self.port = port
        self.healthPath = healthPath
        self.packageManagerAuto = packageManagerAuto
        self.autoHeapGB = autoHeapGB
        self.buildMemoryGB = buildMemoryGB
        self.buildMemoryAuto = buildMemoryAuto
        self.buildAutoHeapGB = buildAutoHeapGB
        self.lastBuildSeconds = lastBuildSeconds
        self.heapFloorGB = heapFloorGB
        self.env = env
    }

    // Custom decoding so projects.json written before these fields still loads. New build-heap
    // fields default by INHERITING the dev-server config (so an existing project keeps the heap the
    // user already set, for the build too), and the learned autoscaler levels start at firstGB.
    enum CodingKeys: String, CodingKey {
        case id, name, path, groupRoot, packageManager, framework, devCommand, buildCommand, workerCommand, previewCommand
        case memoryGB, memoryAuto, port, healthPath, packageManagerAuto
        case autoHeapGB, buildMemoryGB, buildMemoryAuto, buildAutoHeapGB, lastBuildSeconds, heapFloorGB, env
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        // Absent in projects.json written before grouped-add existed — nil ⇒ group by immediate parent.
        groupRoot = try c.decodeIfPresent(String.self, forKey: .groupRoot)
        packageManager = try c.decode(PackageManager.self, forKey: .packageManager)
        framework = try c.decode(Framework.self, forKey: .framework)
        devCommand = try c.decodeIfPresent(String.self, forKey: .devCommand)
        buildCommand = try c.decodeIfPresent(String.self, forKey: .buildCommand)
        // Absent in projects.json written before workers/preview existed — AppState re-detects on load.
        workerCommand = try c.decodeIfPresent(String.self, forKey: .workerCommand)
        previewCommand = try c.decodeIfPresent(String.self, forKey: .previewCommand)
        memoryGB = try c.decode(Int.self, forKey: .memoryGB)
        memoryAuto = try c.decodeIfPresent(Bool.self, forKey: .memoryAuto) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        healthPath = try c.decodeIfPresent(String.self, forKey: .healthPath)
        packageManagerAuto = try c.decodeIfPresent(Bool.self, forKey: .packageManagerAuto) ?? true
        autoHeapGB = try c.decodeIfPresent(Int.self, forKey: .autoHeapGB) ?? HeapScaling.firstGB
        // Build heap defaults to the dev config of an existing project (decoded just above).
        buildMemoryGB = try c.decodeIfPresent(Int.self, forKey: .buildMemoryGB) ?? memoryGB
        buildMemoryAuto = try c.decodeIfPresent(Bool.self, forKey: .buildMemoryAuto) ?? memoryAuto
        buildAutoHeapGB = try c.decodeIfPresent(Int.self, forKey: .buildAutoHeapGB) ?? HeapScaling.firstGB
        lastBuildSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .lastBuildSeconds)
        heapFloorGB = try c.decodeIfPresent(Int.self, forKey: .heapFloorGB)
        env = try c.decodeIfPresent([EnvVar].self, forKey: .env) ?? []
    }
}

extension Project {
    /// Hard floor for the injected heap — guards against a stale, too-low `memoryGB` (e.g. a
    /// leftover `1`) starving the dev server into an out-of-memory crash.
    static let minHeapGB = 2

    /// Clamp a requested heap to `[minHeapGB, systemGB]`.
    private static func clampHeap(_ requested: Int, systemGB: Int?) -> Int {
        var gb = max(Project.minHeapGB, requested)
        if let systemGB, systemGB > 0 { gb = min(gb, max(Project.minHeapGB, systemGB)) }
        return gb
    }

    /// Dev-server heap (GB) injected as `--max-old-space-size`. In **auto** mode it follows the OOM
    /// autoscaler's learned level (`autoHeapGB`, starting at 4 and climbing 4→6→8); only when
    /// `memoryAuto` is off does the explicit `memoryGB` win. Floored at `minHeapGB`, capped at
    /// physical RAM when supplied, so the result is deterministic.
    func effectiveMemoryGB(systemGB: Int? = nil) -> Int {
        Project.clampHeap(memoryAuto ? autoHeapGB : memoryGB, systemGB: systemGB)
    }

    /// The lowest dev-server heap (GB) the shared-memory budget may hand this project: what it has
    /// proven it needs (`heapFloorGB`), or — for a project whose learned level climbed before that was
    /// recorded — the learned level itself. Otherwise just `minHeapGB`.
    var devHeapFloorGB: Int {
        max(Project.minHeapGB, heapFloorGB ?? (autoHeapGB > HeapScaling.firstGB ? autoHeapGB : Project.minHeapGB))
    }

    /// The same floor for a preview, which runs on the BUILD heap: a build level that has climbed is
    /// proof the production bundle needs it.
    var previewHeapFloorGB: Int {
        max(Project.minHeapGB, buildAutoHeapGB > HeapScaling.firstGB ? buildAutoHeapGB : Project.minHeapGB)
    }

    /// Build heap (GB), INDEPENDENT from the dev server. In **auto** mode follows the build OOM
    /// autoscaler's learned level (`buildAutoHeapGB`, 4→6→8); else the explicit `buildMemoryGB`.
    func effectiveBuildMemoryGB(systemGB: Int? = nil) -> Int {
        Project.clampHeap(buildMemoryAuto ? buildAutoHeapGB : buildMemoryGB, systemGB: systemGB)
    }

    /// The health-probe path, normalized to a single leading "/" (defaults to "/" when unset).
    var effectiveHealthPath: String {
        guard let p = healthPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return "/" }
        return p.hasPrefix("/") ? p : "/" + p
    }

    /// `~/Library/Application Support/OwlMonitor/logs` — one file per project lives here.
    static var logsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OwlMonitor/logs", isDirectory: true)
    }

    /// Stable per-project log file: a name slug plus a short id so it survives renames/restarts and
    /// never collides with another project. Both the supervisor (writer) and the CLI (`logs`, via
    /// the hub's `status`) derive the path from here.
    var logFileURL: URL {
        let slug = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        let trimmed = slug.isEmpty ? "project" : String(slug.prefix(40))
        return Project.logsDirectory.appendingPathComponent("\(trimmed)-\(id.uuidString.prefix(8)).log")
    }

    /// The build's OWN log file, alongside the dev-server log. `BuildRunner` streams the full build
    /// output here (fresh per build) so the whole thing survives — the in-app pane and the CLI's
    /// failure tail only show a slice, which hides the header of a big error (e.g. a Rollup dump).
    /// `owl-monitor logs --build` reads this path (carried on `status`).
    var buildLogFileURL: URL {
        logFileURL.deletingPathExtension().appendingPathExtension("build.log")
    }

    /// How many `.log` files sit in `directory` and the bytes they occupy — for the "Clear logs"
    /// affordance (label + confirm text). `directory` defaults to `logsDirectory`; tests pass a temp.
    static func logsSummary(in directory: URL = logsDirectory) -> (count: Int, bytes: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return (0, 0) }
        return files.filter { $0.pathExtension == "log" }.reduce(into: (0, 0)) { acc, url in
            acc.0 += 1
            acc.1 += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
    }

    /// Delete every `.log` file in `directory`, returning how many were removed and the bytes freed.
    /// Best-effort: an unremovable file is skipped. Safe while servers run — a live supervisor keeps
    /// writing to its now-unlinked file (the entry just disappears from the folder), and a fresh log
    /// is recreated on the next launch. `directory` defaults to `logsDirectory`; tests pass a temp.
    @discardableResult
    static func clearLogs(in directory: URL = logsDirectory) -> (removed: Int, bytes: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return (0, 0) }
        var removed = 0, bytes = 0
        for url in files where url.pathExtension == "log" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? fm.removeItem(at: url)) != nil { removed += 1; bytes += size }
        }
        return (removed, bytes)
    }
}
