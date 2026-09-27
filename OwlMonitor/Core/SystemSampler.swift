import Foundation
import Observation
import IOKit   // links IOKit.framework (autolink) so metrics.c's temperature-sensor read resolves

/// One row in the system process table.
struct ProcessRow: Identifiable, Sendable {
    let id: Int32          // pid (negative = a synthetic aggregated row: -2 = build, else -pid)
    let name: String
    let cpuPerCore: Double // per-core % (can exceed 100)
    let memBytes: Double
    var isDevServer = false      // a server SUPERVISED by the app (managed tree)
    var isBuild = false
    var isWorker = false         // a background worker SUPERVISED by the app (managed tree)
    var isExternalDev = false    // a dev server running OUTSIDE the app (identified, not supervised)
    var isExternalBuild = false  // a framework BUILD (nuxt/next/… build|generate|prepare) running OUTSIDE the app
    var isExtension = false      // a VS Code / Cursor extension language-server helper
    var isClaude = false         // a shell/command Claude Code launched (its Bash-tool `/bin/zsh -c`)
    var isPreview = false        // a supervised DevSession serving the production build, not `dev`
    var isSystem = false         // a macOS system/Apple process (executable under /System, /usr/libexec, …)
}

/// Samples ALL system processes (~2 Hz) and exposes the top consumers, like Activity Monitor.
@MainActor
@Observable
final class SystemSampler {
    private(set) var processes: [ProcessRow] = []
    let coreCount: Int
    private(set) var totalMem: Double = 0
    private(set) var systemCPU: Double = 0        // 0…100
    private(set) var systemMemUsed: Double = 0    // bytes
    var systemMemPercent: Double { totalMem > 0 ? systemMemUsed / totalMem * 100 : 0 }
    private(set) var systemSwapUsed: Double = 0   // bytes
    private(set) var systemSwapTotal: Double = 0  // bytes
    var systemSwapPercent: Double { systemSwapTotal > 0 ? systemSwapUsed / systemSwapTotal * 100 : 0 }
    private(set) var loadAverage: Double = 0      // 1-minute load average
    private(set) var cpuTemperature: Double = -1  // °C, or -1 when no thermal sensor is readable
    /// The managed dev-server tree's aggregated CPU% (per-core) and memory, for optional bars.
    var devTreeCPU: Double { processes.first { $0.isDevServer }?.cpuPerCore ?? 0 }
    var devTreeMem: Double { processes.first { $0.isDevServer }?.memBytes ?? 0 }

    /// The Claude Code shells/monitors among the current rows — reassigned ONLY when membership
    /// (pids/names) changes, never on a plain metrics tick. `@Observable` fires on every willSet,
    /// so views that just need "which shells exist" (the terminal tabs, the root layout) would
    /// otherwise re-evaluate at 2 Hz; against this list they re-evaluate only when a shell actually
    /// appears, renames or exits. Live per-shell CPU/mem still comes from `processes`.
    private(set) var claudeShells: [ProcessRow] = []
    var hasClaudeShells: Bool { !claudeShells.isEmpty }

    /// Rolling whole-machine timeline for the Activity charts — one point per sample (~2 Hz), capped
    /// at `maxHistory` (~5 min). Appended only once we have a real CPU delta, so the first tick's
    /// placeholder 0 never shows as a spike. `@Observable` is per-property, so appends here don't
    /// invalidate views that read only the instantaneous meters.
    private(set) var history: [SystemMetricPoint] = []
    private let maxHistory = 300
    private var historyTick = 0

    // Pressure detection: the machine is "stuck" when CPU stays pinned, or memory is full and
    // actively swapping, for a sustained window. Drives the auto kill-suggestions panel.
    enum Pressure: Sendable { case normal, stuck }
    private(set) var pressure: Pressure = .normal
    private(set) var pressureReason = ""
    /// Fired once when entering the stuck state (normal → stuck).
    var onStuck: (() -> Void)?
    private var hotSince: UInt64?
    private let sustainSeconds = 8.0

    private var prev: [Int32: (cpu: Int64, wall: UInt64)] = [:]
    private var nameCache: [Int32: String] = [:]
    private var richNameCache: [Int32: (name: String, ext: Bool, isExtension: Bool, isClaude: Bool, extBuild: Bool)] = [:]
    /// Whether each pid's executable lives under a system path — the path of a live pid never
    /// changes, so one proc_pidpath per process lifetime instead of one per tick.
    private var isSystemCache: [Int32: Bool] = [:]
    /// External dev servers that haven't bound a port yet: pid → uptime-ns after which the port scan
    /// (an fd walk — the expensive part of enrichment) may run again. Absent = entry is final.
    private var portRecheckAt: [Int32: UInt64] = [:]
    private var prevSysTicks: dm_cpu_ticks?
    private var task: Task<Void, Never>?
    private let topN = 40

    /// Supplies one entry PER supervised dev server (id + session-leader pid + readable label), so
    /// each shows as its own highlighted row (e.g. "MiddleSpace :3000") instead of a bare "node" or
    /// one merged row. Tree membership is resolved from the leader during the background pass.
    /// `isPreview` marks a DevSession serving the production build (the row gets an eye icon).
    var devServerInfo: (@MainActor () -> [(id: Int32, leader: pid_t, label: String, isPreview: Bool)])?
    /// Same, for in-progress builds — their trees show as one identified row (like the server).
    var buildInfo: (@MainActor () -> (leaders: [pid_t], label: String)?)?
    /// One entry PER running background worker, so each shows as its own highlighted row
    /// (e.g. "MiddleSpace · worker"), like a supervised server.
    var workerInfo: (@MainActor () -> [(id: Int32, leader: pid_t, label: String)])?

    init() {
        coreCount = max(1, ProcessInfo.processInfo.processorCount)
        var mem = dm_mem_info()
        _ = dm_system_mem(&mem)
        totalMem = Double(mem.total)
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Thermal sensors are read on every `temperatureEvery`-th tick (~10 s), not every 2 s: the read
    /// goes to the hardware sensor service and was one of the costliest calls in a sampling pass,
    /// while the temperature itself only moves over tens of seconds.
    private static let temperatureEvery = 5
    private var temperatureTick = 0

    /// One tick: snapshot the supervised-leader info and caches on the main actor, run the heavy
    /// syscall sweep in `collect` OFF the main actor, then publish the results. The UI never blocks
    /// on the per-process rusage/name/argv syscalls, however loaded the machine is.
    private func sample() async {
        temperatureTick += 1
        let input = SampleInput(
            devs: devServerInfo?() ?? [], build: buildInfo?(), workers: workerInfo?() ?? [],
            prev: prev, nameCache: nameCache, richNameCache: richNameCache,
            isSystemCache: isSystemCache,
            portRecheckAt: portRecheckAt, prevSysTicks: prevSysTicks,
            coreCount: coreCount, totalMem: totalMem, topN: topN,
            readTemperature: temperatureTick % Self.temperatureEvery == 1)
        let out = await Task.detached(priority: .utility) { Self.collect(input) }.value

        prevSysTicks = out.sysTicks
        // Publish a reading only when the change is VISIBLE at the meters' display precision
        // (0.1 GB, 0.01 load, 1 °C, 1 %): `@Observable` notifies on every reassignment, equal or
        // not, so republishing an unchanged value re-rendered every meter tile twice a second for
        // nothing. History (below) still records the exact values every tick.
        let memQuantum = 100_000_000.0   // 0.1 GB display step
        if Int(out.memUsed / memQuantum) != Int(systemMemUsed / memQuantum) { systemMemUsed = out.memUsed }
        if let swap = out.swap {
            if Int(swap.used / memQuantum) != Int(systemSwapUsed / memQuantum) { systemSwapUsed = swap.used }
            if swap.total != systemSwapTotal { systemSwapTotal = swap.total }
        }
        if Int(out.loadAvg * 100) != Int(loadAverage * 100) { loadAverage = out.loadAvg }
        // NaN = not read this tick (see `temperatureEvery`) — keep the last reading.
        if !out.temperature.isNaN, Int(out.temperature.rounded()) != Int(cpuTemperature.rounded()) {
            cpuTemperature = out.temperature
        }
        processes = out.processes
        let shells = out.processes.filter(\.isClaude)
        if shells.count != claudeShells.count
            || !zip(shells, claudeShells).allSatisfy({ $0.id == $1.id && $0.name == $1.name }) {
            claudeShells = shells
        }
        prev = out.prev
        nameCache = out.nameCache
        richNameCache = out.richNameCache
        isSystemCache = out.isSystemCache
        portRecheckAt = out.portRecheckAt

        // Timeline history — only once we have a real CPU delta (the first tick has no previous
        // ticks to diff, so `out.systemCPU` is nil; skip it rather than record a 0-CPU spike).
        if let cpu = out.systemCPU {
            if Int(cpu) != Int(systemCPU) { systemCPU = cpu }
            let point = SystemMetricPoint(
                id: historyTick, date: Date(), systemCPU: cpu,
                memUsed: out.memUsed, memTotal: totalMem,
                swapUsed: systemSwapUsed, swapTotal: systemSwapTotal,
                // On ticks that skip the sensor (NaN), carry the last reading — a NaN point would
                // break the timeline chart.
                loadAverage: out.loadAvg, temperature: out.temperature.isNaN ? cpuTemperature : out.temperature)
            MetricChartMath.appendCapped(&history, point, cap: maxHistory)
            historyTick += 1
        }

        updatePressure()
    }

    /// Plain-value snapshot handed to the background pass (and the updated caches handed back).
    private struct SampleInput: Sendable {
        var devs: [(id: Int32, leader: pid_t, label: String, isPreview: Bool)]
        var build: (leaders: [pid_t], label: String)?
        var workers: [(id: Int32, leader: pid_t, label: String)]
        var prev: [Int32: (cpu: Int64, wall: UInt64)]
        var nameCache: [Int32: String]
        var richNameCache: [Int32: (name: String, ext: Bool, isExtension: Bool, isClaude: Bool, extBuild: Bool)]
        var isSystemCache: [Int32: Bool]
        var portRecheckAt: [Int32: UInt64]
        var prevSysTicks: dm_cpu_ticks?
        var coreCount: Int
        var totalMem: Double
        var topN: Int
        /// Read the thermal sensors this tick? Only every `temperatureEvery` ticks — see there.
        var readTemperature: Bool
    }

    private struct SampleOutput: Sendable {
        var systemCPU: Double?   // nil on the very first tick (no previous tick delta)
        var sysTicks: dm_cpu_ticks
        var memUsed: Double
        var swap: (used: Double, total: Double)?
        var loadAvg: Double
        var temperature: Double
        var processes: [ProcessRow]
        var prev: [Int32: (cpu: Int64, wall: UInt64)]
        var nameCache: [Int32: String]
        var richNameCache: [Int32: (name: String, ext: Bool, isExtension: Bool, isClaude: Bool, extBuild: Bool)]
        var isSystemCache: [Int32: Bool]
        var portRecheckAt: [Int32: UInt64]
    }

    /// The heavy per-tick pass: system stats, the full pid sweep (rusage + name per process), session
    /// grouping, aggregation and name enrichment — every syscall and file read happens here, off the
    /// main actor, against value snapshots of the caches.
    nonisolated private static func collect(_ s: SampleInput) -> SampleOutput {
        // System-wide CPU (tick deltas) and memory for the top progress bars.
        var ticks = dm_cpu_ticks()
        _ = dm_system_cpu_ticks(&ticks)
        var systemCPU: Double?
        if let prevTicks = s.prevSysTicks {
            let dTotal = Double(ticks.total &- prevTicks.total)
            let dIdle = Double(ticks.idle &- prevTicks.idle)
            if dTotal > 0 { systemCPU = max(0, min(100, (1 - dIdle / dTotal) * 100)) }
        }
        var sysMem = dm_mem_info()
        _ = dm_system_mem(&sysMem)
        var swap: (used: Double, total: Double)?
        var sysSwap = dm_mem_info()
        if dm_system_swap(&sysSwap) == 0 {
            swap = (Double(sysSwap.used), Double(sysSwap.total))
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(dm_all_pids(&pids, 8192))

        var rows: [ProcessRow] = []
        rows.reserveCapacity(count)
        var newPrev: [Int32: (cpu: Int64, wall: UInt64)] = [:]
        var seenNames: [Int32: String] = [:]
        // Group every pid by session id in the same pass, so each supervised tree below resolves
        // via one dictionary lookup instead of its own full-pid scan (dm_session_pids per leader).
        var pidsBySid: [pid_t: Set<Int32>] = [:]
        var nameBuffer = [CChar](repeating: 0, count: 1024)

        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            let stat = dm_proc_stat_for(pid)
            if stat.valid != 1 { continue }

            let sid = getsid(pid)
            if sid > 0 { pidsBySid[sid, default: []].insert(pid) }

            newPrev[pid] = (stat.cpu_time_ns, now)
            var cpu = 0.0
            if let p = s.prev[pid], stat.cpu_time_ns >= p.cpu, now > p.wall {
                cpu = Double(stat.cpu_time_ns - p.cpu) / Double(now - p.wall) * 100
            }

            let name: String
            if let cached = s.nameCache[pid] {
                name = cached
            } else if Int(dm_proc_name(pid, &nameBuffer, 1024)) > 0 {
                name = String(cString: nameBuffer)
            } else {
                name = "pid \(pid)"
            }
            seenNames[pid] = name

            rows.append(ProcessRow(id: pid, name: name, cpuPerCore: cpu, memBytes: Double(stat.phys_footprint)))
        }

        // A dead leader resolves to an empty set and its entry drops out — matching the previous
        // behaviour of omitting supervised rows whose tree has no live pids.
        func members(of leader: pid_t) -> Set<Int32> {
            guard leader > 0 else { return [] }
            let sid = getsid(leader)
            return sid > 0 ? (pidsBySid[sid] ?? []) : []
        }
        let devs = s.devs.map { (id: $0.id, pids: members(of: $0.leader), label: $0.label, isPreview: $0.isPreview) }
            .filter { !$0.pids.isEmpty }
        let workers = s.workers.map { (id: $0.id, pids: members(of: $0.leader), label: $0.label) }
            .filter { !$0.pids.isEmpty }
        var build: (pids: Set<Int32>, label: String)?
        if let b = s.build {
            var buildPids = Set<Int32>()
            for leader in b.leaders { buildPids.formUnion(members(of: leader)) }
            if !buildPids.isEmpty { build = (buildPids, b.label) }
        }

        // Identify external dev servers among the NOT-yet-supervised rows BEFORE aggregation, so a
        // low-impact one (e.g. an idle preview server) is still found — enrichment used to run only
        // on the few rows that survived the impact filter below, which silently dropped a quiet
        // external server. `aggregate` exempts any row flagged `isExternalDev` from that filter, so
        // it's always shown, like a supervised row. Supervised-tree pids are skipped (wasted lookup —
        // they're already folded into their tree's row regardless of this flag).
        let supervisedPids = devs.reduce(into: Set<Int32>()) { $0.formUnion($1.pids) }
            .union(workers.flatMap(\.pids))
            .union(build?.pids ?? [])
        var rich = s.richNameCache
        var recheckAt = s.portRecheckAt
        var isSystem = s.isSystemCache
        let enrichedRows = rows.map { row -> ProcessRow in
            // Enrich every real (unsupervised) row — not just the "generic"-named ones — so an
            // app-bundled binary with an opaque name (e.g. Warp's "stable") is identified from its
            // `.app` path too. It's cheap: enrichment reads argv (and the system-path check runs
            // proc_pidpath) once per pid LIFETIME — both are cached across ticks for every scanned
            // pid, so a steady-state tick does near-zero syscalls here.
            guard row.id > 0, !supervisedPids.contains(row.id) else { return row }
            let e = enrichedName(pid: row.id, comm: row.name, now: now,
                                 cache: &rich, portRecheckAt: &recheckAt)
            let system: Bool
            if let cached = isSystem[row.id] {
                system = cached
            } else {
                system = dm_proc_is_system(row.id) != 0
                isSystem[row.id] = system
            }
            guard e.ext || e.isExtension || e.isClaude || e.extBuild || e.name != row.name || system else { return row }
            return ProcessRow(id: row.id, name: e.name, cpuPerCore: row.cpuPerCore,
                              memBytes: row.memBytes, isExternalDev: e.ext,
                              isExternalBuild: e.extBuild,
                              isExtension: e.isExtension, isClaude: e.isClaude, isSystem: system)
        }

        // Aggregate the dev-server and build trees into single identified rows; identified external
        // dev servers are always kept too; otherwise surface only processes with a real performance
        // impact. (Pure + testable — see SystemSampler.aggregate.)
        let result = aggregate(rows: enrichedRows, devs: devs, build: build, workers: workers,
                               coreCount: s.coreCount, totalMem: s.totalMem, topN: s.topN)

        // Prune the enrichment caches by the pids SCANNED this tick, not by the shown rows: an entry
        // must survive for every live process, or the next tick re-reads its argv (a KERN_PROCARGS2
        // sysctl + an argmax-sized malloc) and re-walks node runtimes' fd tables — for the hundreds
        // of processes that never make the table. Pruning to the visible rows silently cost more per
        // tick than everything else in this sweep combined.
        let scanned = Set(seenNames.keys)
        rich = rich.filter { scanned.contains($0.key) }
        recheckAt = recheckAt.filter { scanned.contains($0.key) }
        isSystem = isSystem.filter { scanned.contains($0.key) }

        return SampleOutput(systemCPU: systemCPU, sysTicks: ticks, memUsed: Double(sysMem.used),
                            swap: swap, loadAvg: dm_load_avg(),
                            temperature: s.readTemperature ? dm_cpu_temperature() : .nan,
                            processes: result, prev: newPrev, nameCache: seenNames,
                            richNameCache: rich, isSystemCache: isSystem, portRecheckAt: recheckAt)
    }

    private func updatePressure() {
        let now = DispatchTime.now().uptimeNanoseconds
        // Aggregate 0–100 CPU attributable to builds (the supervised build row id -2 plus any external
        // build), subtracted from the pressure signal so a build alone never trips it.
        let buildCPU = processes
            .filter { $0.isBuild || $0.isExternalBuild }
            .reduce(0.0) { $0 + $1.cpuPerCore } / Double(coreCount)
        let r = Self.evaluatePressure(cpu: systemCPU, buildCPU: buildCPU, memPercent: systemMemPercent,
                                      swapPercent: systemSwapPercent, hotSince: hotSince,
                                      now: now, sustainSeconds: sustainSeconds, current: pressure)
        hotSince = r.hotSince
        pressure = r.pressure
        if r.justStuck {
            pressureReason = r.reason
            onStuck?()
        }
    }

    // MARK: - Pure logic (testable without the C metrics or the run loop)

    /// Aggregates each dev-server tree into its OWN identified row, the build tree into one row
    /// (id -2), always keeps rows already flagged `isExternalDev` (an identified dev server running
    /// outside the app), and otherwise keeps only other processes with real impact (heavy CPU or
    /// memory), ranked, capped at `topN`.
    nonisolated static func aggregate(
        rows: [ProcessRow],
        devs: [(id: Int32, pids: Set<Int32>, label: String, isPreview: Bool)],
        build: (pids: Set<Int32>, label: String)?,
        workers: [(id: Int32, pids: Set<Int32>, label: String)] = [],
        coreCount: Int, totalMem: Double, topN: Int
    ) -> [ProcessRow] {
        let cores = Double(coreCount)
        let heavyMem = 600.0 * 1_048_576   // 600 MB
        let busyCPUPerCore = 25.0          // ~a quarter of a core or more
        func impact(_ row: ProcessRow) -> Double {
            row.cpuPerCore / cores + (totalMem > 0 ? row.memBytes / totalMem * 100 : 0)
        }
        // Map each pid to its dev-server / worker index so trees are summed PER process, not together.
        var devIndexByPid: [Int32: Int] = [:]
        for (i, d) in devs.enumerated() { for p in d.pids { devIndexByPid[p] = i } }
        var workerIndexByPid: [Int32: Int] = [:]
        for (i, w) in workers.enumerated() { for p in w.pids { workerIndexByPid[p] = i } }
        let buildPids = build?.pids ?? []

        var devCPU = [Double](repeating: 0, count: devs.count)
        var devMem = [Double](repeating: 0, count: devs.count)
        var workerCPU = [Double](repeating: 0, count: workers.count)
        var workerMem = [Double](repeating: 0, count: workers.count)
        var buildCPU = 0.0, buildMem = 0.0
        var others: [ProcessRow] = []
        var externalDevs: [ProcessRow] = []
        var externalBuilds: [ProcessRow] = []
        var claudeShells: [ProcessRow] = []
        for row in rows {
            if let gi = devIndexByPid[row.id] {
                devCPU[gi] += row.cpuPerCore; devMem[gi] += row.memBytes
            } else if let wi = workerIndexByPid[row.id] {
                workerCPU[wi] += row.cpuPerCore; workerMem[wi] += row.memBytes
            } else if !buildPids.isEmpty, buildPids.contains(row.id) {
                buildCPU += row.cpuPerCore; buildMem += row.memBytes
            } else if row.isExternalDev {
                externalDevs.append(row)
            } else if row.isExternalBuild {
                externalBuilds.append(row)
            } else if row.isClaude {
                claudeShells.append(row)
            } else {
                others.append(row)
            }
        }
        var result: [ProcessRow] = []
        // One row per supervised server (always shown, even when momentarily idle).
        for (i, d) in devs.enumerated() {
            result.append(ProcessRow(id: d.id, name: d.label, cpuPerCore: devCPU[i],
                                     memBytes: devMem[i], isDevServer: true, isPreview: d.isPreview))
        }
        // One row per running worker.
        for (i, w) in workers.enumerated() {
            result.append(ProcessRow(id: w.id, name: w.label, cpuPerCore: workerCPU[i],
                                     memBytes: workerMem[i], isWorker: true))
        }
        if let build, !buildPids.isEmpty {
            result.append(ProcessRow(id: -2, name: build.label, cpuPerCore: buildCPU, memBytes: buildMem, isBuild: true))
        }
        // Identified external dev servers ALWAYS show, like a supervised row — regardless of impact.
        result.append(contentsOf: externalDevs.sorted { impact($0) > impact($1) })
        // Unsupervised framework builds ALWAYS show too — a build is heavy by nature, and the user
        // wants to see (and be able to stop) one that's running outside the app.
        result.append(contentsOf: externalBuilds.sorted { impact($0) > impact($1) })
        // Collapse Claude *subshells*: the Bash tool forks a child `/bin/zsh` for a pipeline or `eval`
        // that inherits the same shell-snapshot argv, so it also matches `isClaudeShell` — which made
        // ONE running command show up as two shells (a tab/row each). Keep session roots: drop a Claude
        // shell that is a child of another Claude shell. Background `monitor`s are detached (never
        // children), and are excluded so one can never be folded away.
        if claudeShells.count > 1 {
            let shellPids = Set(claudeShells.map(\.id))
            let monitorPids = Set(claudeShells.filter { $0.name.localizedCaseInsensitiveContains("monitor") }.map(\.id))
            var subshells = Set<Int32>()
            for parent in claudeShells {
                for child in Self.childPids(of: parent.id) where shellPids.contains(child) && !monitorPids.contains(child) {
                    subshells.insert(child)
                }
            }
            claudeShells.removeAll { subshells.contains($0.id) }
        }
        // Claude Code's shells ALWAYS show too — even a near-idle one (e.g. a background `tail -f`
        // monitor) matters here, so no impact filter; the user wants to see and be able to stop them.
        result.append(contentsOf: claudeShells.sorted { impact($0) > impact($1) })
        result.append(contentsOf: others
            .filter { $0.cpuPerCore >= busyCPUPerCore || $0.memBytes >= heavyMem }
            .sorted { impact($0) > impact($1) }
            .prefix(topN))
        return result
    }

    /// Pure pressure state machine: stuck when NON-build CPU is pinned, or memory is full while
    /// swapping, for a sustained window; clears with hysteresis. `justStuck` marks the normal → stuck
    /// transition. `buildCPU` is the aggregate 0–100 CPU a running build accounts for; it's subtracted
    /// first so a plain build — which maxes the cores on purpose — never reads as a stuck machine.
    nonisolated static func evaluatePressure(
        cpu: Double, buildCPU: Double, memPercent: Double, swapPercent: Double,
        hotSince: UInt64?, now: UInt64, sustainSeconds: Double, current: Pressure
    ) -> (pressure: Pressure, reason: String, hotSince: UInt64?, justStuck: Bool) {
        // A build saturating the cores is expected, bounded work that finishes — not a stuck machine.
        // Discount it so pressure fires only when something ELSE is pinning the cores. (Memory pressure
        // below stays on raw memory/swap: a build thrashing RAM IS real pressure.)
        let cpu = max(0, cpu - buildCPU)
        let cpuHot = cpu >= 90
        let memHot = memPercent >= 90 && swapPercent >= 50
        if cpuHot || memHot {
            let since = hotSince ?? now
            let elapsed = Double(now &- since) / 1_000_000_000
            if current == .normal, elapsed >= sustainSeconds {
                let reason = cpuHot
                    ? "CPU pinned at \(Int(cpu))% for \(Int(elapsed))s"
                    : "Memory \(Int(memPercent))% full, swapping (\(Int(swapPercent))%)"
                return (.stuck, reason, since, true)
            }
            return (current, "", since, false)
        } else if cpu < 70, memPercent < 85 {   // hysteresis: clear once it cools
            return (.normal, "", nil, false)
        }
        return (current, "", hotSince, false)
    }

    /// JS/TS dev-server runtimes we port-probe when the argv matches no known framework — kept narrow
    /// (node/bun/deno) so a browser, Electron app or daemon that also happens to open a port isn't
    /// mistaken for a dev server.
    nonisolated private static func isDevRuntime(_ comm: String) -> Bool {
        switch comm.lowercased() { case "node", "bun", "deno": return true; default: return false }
    }

    nonisolated private static func enrichedName(
        pid: Int32, comm: String, now: UInt64,
        cache: inout [Int32: (name: String, ext: Bool, isExtension: Bool, isClaude: Bool, extBuild: Bool)],
        portRecheckAt: inout [Int32: UInt64]
    ) -> (name: String, ext: Bool, isExtension: Bool, isClaude: Bool, extBuild: Bool) {
        if let cached = cache[pid] {
            // An external dev server that hasn't bound a port yet re-scans only once its recheck is
            // due — walking its fds for the port is the expensive part. Everything else is final.
            guard let due = portRecheckAt[pid], now >= due else { return cached }
        }
        var buffer = [CChar](repeating: 0, count: 8192)
        let n = Int(dm_proc_args(pid, &buffer, 8192))
        let args = n > 0 ? String(cString: buffer) : ""
        // A shell Claude Code launched (its Bash tool runs every command as `/bin/zsh -c` that first
        // sources a unique shell-snapshot — a signature nothing else produces). Surface it so the
        // background "monitors" and foreground commands Claude runs show in Activity and can be stopped.
        if isClaudeShell(args) {
            // A background *monitor* (a `while true` / `until …; do sleep …; done` polling loop Claude
            // left running to watch for a condition) vs a one-shot foreground command — Claude Code
            // itself draws this distinction, so mirror it in the label.
            let name = isClaudeMonitor(args) ? "Claude · monitor" : "Claude · shell"
            let entry = (name: name, ext: false, isExtension: false, isClaude: true, extBuild: false)
            cache[pid] = entry
            portRecheckAt.removeValue(forKey: pid)
            return entry
        }
        // A dev server started OUTSIDE the app: identify it like the managed one
        // ("MiddleSpace :3001") instead of a bare "node", and flag it external so the table can
        // give it the same format in a different colour. It stays unsupervised (no probe/recycle).
        // Two ways to qualify:
        //   (1) argv matches a known framework (nuxt/next/vite/astro/…) — fast, no port scan needed,
        //       and we keep rechecking until it binds so a still-starting heavy bundler isn't missed.
        //   (2) it's a JS/TS dev runtime (node/bun/deno) actually LISTENING on a TCP port — catches
        //       Express/Fastify/Nest/nodemon/plain-node/Bun/Deno servers that match no framework
        //       pattern, so nothing that binds a port silently vanishes from Activity. The port is
        //       the proof it's a server, so no framework allow-list is needed for this path.
        let isFramework = ResourceAdvisor.looksLikeDevServer(argv: args)
        if isFramework || isDevRuntime(comm) {
            let port = Int(dm_proc_listen_port(pid))
            if isFramework || port > 0 {
                let project = projectName(fromArgs: args) ?? comm
                let entry = (name: project + (port > 0 ? " :\(port)" : ""),
                             ext: true, isExtension: false, isClaude: false, extBuild: false)
                cache[pid] = entry
                if port > 0 {
                    portRecheckAt.removeValue(forKey: pid)           // port bound — entry is final
                } else {
                    portRecheckAt[pid] = now &+ 10_000_000_000       // framework still binding — retry ~10 s
                }
                return entry
            }
            // A dev runtime that matches no framework and isn't listening (yet): not an identifiable
            // server — fall through to generic naming. We don't reschedule a recheck, so idle node
            // tooling (language servers, build/lint steps) isn't re-scanned every tick.
        }
        // A framework BUILD (nuxt/next/… build|generate|prepare) started OUTSIDE the app: name it like
        // the managed build ("<project> · build") and flag it external-build, so Activity shows it as a
        // build (hammer, always visible) instead of a mystery heavy "node" or an idle "Claude · shell".
        // Mirrors the isExternalDev path for an unsupervised server; the non-server subcommand that
        // stops looksLikeDevServer from firing above is exactly the signal `externalTaskName` keys on.
        if let task = externalTaskName(args) {
            let entry = (name: task, ext: false, isExtension: false, isClaude: false, extBuild: true)
            cache[pid] = entry
            portRecheckAt.removeValue(forKey: pid)
            return entry
        }
        // A WebKit XPC service (com.apple.WebKit.WebContent / GPU / Networking) is spawned by the
        // WebKit framework, so — unlike an Electron helper — its argv names no owning .app. Attribute
        // it to the app that owns the web view via the responsible process, so Safari's WebContent
        // shows Safari's name + icon instead of a bare "com.apple.WebKit.WebContent" system row. Other
        // WebKit hosts (Mail, App Store, …) get their own name the same way.
        if comm.hasPrefix("com.apple.WebKit.") {
            let owner = dm_responsible_pid(pid)
            if owner > 1, owner != pid {
                var nameBuf = [CChar](repeating: 0, count: 1024)
                let named = dm_proc_name(owner, &nameBuf, 1024) > 0 ? String(cString: nameBuf) : ""
                if !named.isEmpty, named != comm {
                    let entry = (name: named, ext: false, isExtension: false, isClaude: false, extBuild: false)
                    cache[pid] = entry
                    portRecheckAt.removeValue(forKey: pid)
                    return entry
                }
            }
        }
        let d = describe(comm: comm, args: args)
        let entry = (name: d.name, ext: false, isExtension: d.isExtension, isClaude: false, extBuild: false)
        cache[pid] = entry
        portRecheckAt.removeValue(forKey: pid)
        return entry
    }

    /// True when argv carries Claude Code's Bash-tool shell-snapshot signature.
    nonisolated private static func isClaudeShell(_ args: String) -> Bool {
        args.contains("shell-snapshots/snapshot-")
    }

    /// A Claude shell that's a background *monitor* — a polling loop (`while true` / `while :` /
    /// `until …`) left running to watch for a condition, not a one-shot foreground command.
    nonisolated private static func isClaudeMonitor(_ args: String) -> Bool {
        args.contains("while true") || args.contains("while :") || args.contains("until ")
    }

    /// Direct child pids of `pid` (wraps `dm_child_pids`). Used to fold a Bash-tool subshell into its
    /// parent so one command isn't listed as two shells.
    nonisolated private static func childPids(of pid: Int32) -> [Int32] {
        var buf = [pid_t](repeating: 0, count: 64)
        let n = dm_child_pids(pid, &buf, Int32(buf.count))
        return n > 0 ? Array(buf.prefix(Int(min(n, Int32(buf.count))))) : []
    }

    /// The project folder name from a dev-server argv: the directory just before `/node_modules/`
    /// (e.g. ".../MiddleSpace/node_modules/.bin/nuxt" → "MiddleSpace"). nil if not derivable.
    nonisolated static func projectName(fromArgs args: String) -> String? {
        guard let r = args.range(of: "/node_modules/") else { return nil }
        let before = args[..<r.lowerBound]
        guard let slash = before.lastIndex(of: "/") else { return nil }
        let name = String(before[before.index(after: slash)...])
        return name.isEmpty ? nil : name
    }

    nonisolated private static func describe(comm: String, args: String) -> (name: String, isExtension: Bool) {
        // VS Code / Cursor language servers run from an extension folder referenced in their argv.
        // Read that extension's own package.json so the name comes from the extension, never a
        // hardcoded list. Falls back to the folder name, then the .app bundle, then the bare name.
        if let dir = extensionDir(inArgs: args),
           let name = extensionDisplayName(dir: dir) ?? extensionFolderName(dir) {
            return (name, true)
        }
        // Claude Code itself (its node CLI / helpers) — otherwise it shows as a bare version like
        // "2.1.202". Match its package path so a bumped version keeps identifying.
        if args.contains("@anthropic-ai/claude-code") || args.contains("/claude-code/") {
            return ("Claude Code", false)
        }
        // A framework task run OUTSIDE the app (e.g. `node …/MiddleSpace/node_modules/.bin/nuxt build`)
        // — name it "<project> · <task>" so a heavy orphan build/generate isn't a mystery "node" row.
        if let task = externalTaskName(args) { return (task, false) }
        // Otherwise identify the owning app from the bundle path in argv
        // (e.g. ".../Claude.app/Contents/Helpers/.../2.1.179" → "Claude").
        return (appBundleName(inArgs: args) ?? comm, false)
    }

    /// A framework CLI task running unsupervised, named `<project> · <task>` — e.g.
    /// `node .../<project>/node_modules/.bin/nuxt build` → "myapp · build". Only the non-server
    /// tasks (build/generate/prepare) reach here; dev/preview/start are handled as dev servers.
    nonisolated private static func externalTaskName(_ args: String) -> String? {
        guard let project = projectName(fromArgs: args) else { return nil }
        let tools: Set<String> = ["nuxt", "next", "vite", "astro", "ng", "vinxi", "remix", "nuxi"]
        let tasks: Set<String> = ["build", "generate", "prepare"]
        let tokens = args.split(separator: " ").map(String.init)
        for (i, t) in tokens.enumerated() where i + 1 < tokens.count {
            let base = t.split(separator: "/").last.map(String.init) ?? t
            if tools.contains(base), tasks.contains(tokens[i + 1]) {
                return "\(project) · \(tokens[i + 1])"
            }
        }
        return nil
    }

    /// The `<Name>` of the first `…/<Name>.app/…` bundle referenced in argv.
    nonisolated private static func appBundleName(inArgs args: String) -> String? {
        guard let r = args.range(of: ".app/") else { return nil }
        let before = args[..<r.lowerBound]
        guard let slash = before.lastIndex(of: "/") else { return nil }
        let name = String(before[before.index(after: slash)...])
        return name.isEmpty ? nil : name
    }

    /// The `…/extensions/<publisher>.<name>-<version>` directory referenced by an argv token.
    nonisolated private static func extensionDir(inArgs args: String) -> String? {
        for token in args.split(separator: " ") {
            guard let ext = token.range(of: "/extensions/"),
                  let pathStart = token.firstIndex(of: "/")           // strip any `--flag=` prefix
            else { continue }
            let afterFolder = token[ext.upperBound...]
            let folderEnd = afterFolder.firstIndex(of: "/") ?? token.endIndex
            return String(token[pathStart..<folderEnd])
        }
        return nil
    }

    /// `displayName` from the extension's package.json, resolving `%key%` via package.nls.json.
    nonisolated private static func extensionDisplayName(dir: String) -> String? {
        let base = URL(fileURLWithPath: dir)
        guard let data = try? Data(contentsOf: base.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var name = (obj["displayName"] as? String) ?? (obj["name"] as? String)
        if let n = name, n.hasPrefix("%"), n.hasSuffix("%"), n.count > 2 {
            let key = String(n.dropFirst().dropLast())
            if let nlsData = try? Data(contentsOf: base.appendingPathComponent("package.nls.json")),
               let nls = try? JSONSerialization.jsonObject(with: nlsData) as? [String: Any] {
                name = (nls[key] as? String) ?? ((nls[key] as? [String: Any])?["message"] as? String) ?? n
            }
        }
        guard let result = name, !result.isEmpty else { return nil }
        return result
    }

    /// Last-resort readable name from the folder `publisher.name-version` → `name`.
    nonisolated private static func extensionFolderName(_ dir: String) -> String? {
        let folder = (dir as NSString).lastPathComponent
        let afterPublisher = folder.split(separator: ".").dropFirst().joined(separator: ".")
        let base = afterPublisher.isEmpty ? folder : afterPublisher
        // Drop a trailing -1.2.3 version.
        let parts = base.split(separator: "-")
        let nameParts = parts.prefix { !($0.first?.isNumber ?? false) }
        let name = nameParts.joined(separator: "-")
        return name.isEmpty ? nil : name
    }
}
