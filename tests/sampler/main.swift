import Foundation

// Tests the pure logic behind the activity table: SystemSampler.aggregate (dev/build identified
// rows + impact filtering) and SystemSampler.evaluatePressure (the stuck-machine state machine).

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let GB = 1_073_741_824.0
let MB = 1_048_576.0

// --- aggregate ---
let rows = [
    ProcessRow(id: 100, name: "node", cpuPerCore: 50, memBytes: 200 * MB),     // dev member
    ProcessRow(id: 101, name: "esbuild", cpuPerCore: 30, memBytes: 100 * MB),  // dev member
    ProcessRow(id: 200, name: "node", cpuPerCore: 80, memBytes: 300 * MB),     // build member
    ProcessRow(id: 300, name: "Chrome", cpuPerCore: 90, memBytes: 2000 * MB),  // heavy other
    ProcessRow(id: 301, name: "idle", cpuPerCore: 1, memBytes: 10 * MB),       // light → filtered
]
let agg = SystemSampler.aggregate(
    rows: rows,
    devs: [(id: -1, pids: [100, 101], label: "MiddleSpace :3000", isPreview: false)],
    build: (pids: [200], label: "Build · MiddleSpace"),
    coreCount: 8, totalMem: 8 * GB, topN: 40)

let devRow = agg.first { $0.id == -1 }
chk(devRow != nil && devRow!.isDevServer, "aggregate: dev row present + flagged")
chk(devRow?.isPreview == false, "aggregate: a plain dev row is not flagged preview")
chk(devRow?.cpuPerCore == 80, "aggregate: dev CPU summed (50+30)", "\(devRow?.cpuPerCore ?? -1)")

// A preview session is still an isDevServer row (so it's always shown, keeps its accent colour,
// etc.) but ALSO carries isPreview, so the UI can swap the server icon for an eye instead of
// appending " · preview" text to the name.
let aggPreview = SystemSampler.aggregate(
    rows: [ProcessRow(id: 700, name: "node", cpuPerCore: 10, memBytes: 50 * MB)],
    devs: [(id: -3, pids: [700], label: "MiddleSpace :3000", isPreview: true)],
    build: nil, coreCount: 8, totalMem: 8 * GB, topN: 40)
let previewRow = aggPreview.first { $0.id == -3 }
chk(previewRow != nil && previewRow!.isDevServer && previewRow!.isPreview,
    "aggregate: preview row is a dev-server row ALSO flagged preview", "\(String(describing: previewRow))")
let buildRow = agg.first { $0.id == -2 }
chk(buildRow != nil && buildRow!.isBuild, "aggregate: build row identified like the server")
chk(buildRow?.cpuPerCore == 80, "aggregate: build CPU", "\(buildRow?.cpuPerCore ?? -1)")
chk(agg.contains { $0.id == 300 }, "aggregate: heavy other process shown")
chk(!agg.contains { $0.id == 301 }, "aggregate: light process filtered out")
chk(!agg.contains { [100, 101, 200].contains($0.id) }, "aggregate: tree members not double-listed")

let aggIdle = SystemSampler.aggregate(
    rows: [ProcessRow(id: 200, name: "node", cpuPerCore: 1, memBytes: 5 * MB)],
    devs: [], build: (pids: [200], label: "Build · X"),
    coreCount: 8, totalMem: 8 * GB, topN: 40)
chk(aggIdle.contains { $0.id == -2 }, "aggregate: idle build still shown (always-on like server)")

// Workers: one identified row per worker, tree summed, members not double-listed.
let aggWorker = SystemSampler.aggregate(
    rows: [
        ProcessRow(id: 400, name: "node", cpuPerCore: 20, memBytes: 150 * MB),
        ProcessRow(id: 401, name: "tsx", cpuPerCore: 15, memBytes: 50 * MB),
    ],
    devs: [], build: nil,
    workers: [(id: -4, pids: [400, 401], label: "MiddleSpace · worker")],
    coreCount: 8, totalMem: 8 * GB, topN: 40)
let workerRow = aggWorker.first { $0.id == -4 }
chk(workerRow != nil && workerRow!.isWorker, "aggregate: worker row present + flagged")
chk(workerRow?.cpuPerCore == 35, "aggregate: worker CPU summed (20+15)", "\(workerRow?.cpuPerCore ?? -1)")
chk(workerRow?.memBytes == 200 * MB, "aggregate: worker mem summed", "\(workerRow?.memBytes ?? -1)")
chk(!aggWorker.contains { $0.id == 400 || $0.id == 401 }, "aggregate: worker members not double-listed")

// An identified external dev server ALWAYS shows, even when idle (below the busy/heavy impact
// threshold) — same guarantee as a supervised row, since it would otherwise vanish from the
// Activity table the moment it goes quiet (e.g. an idle preview server).
let aggExternal = SystemSampler.aggregate(
    rows: [
        ProcessRow(id: 500, name: "MiddleSpace · preview :3200", cpuPerCore: 0.1, memBytes: 20 * MB,
                  isExternalDev: true),
        ProcessRow(id: 501, name: "idle", cpuPerCore: 0.1, memBytes: 20 * MB),   // plain other, same size
    ],
    devs: [], build: nil, coreCount: 8, totalMem: 8 * GB, topN: 40)
chk(aggExternal.contains { $0.id == 500 && $0.isExternalDev }, "aggregate: idle external dev server still shown")
chk(!aggExternal.contains { $0.id == 501 }, "aggregate: an equally-light plain process is still filtered")

// An unsupervised framework build is always shown too (like an external server) — even momentarily
// quiet — instead of being filtered as a plain heavy "node" or hidden under its Claude shell.
let aggExtBuild = SystemSampler.aggregate(
    rows: [
        ProcessRow(id: 550, name: "MiddleSpace · build", cpuPerCore: 0.2, memBytes: 30 * MB,
                  isExternalBuild: true),
        ProcessRow(id: 551, name: "idle", cpuPerCore: 0.2, memBytes: 30 * MB),   // plain other, same size
    ],
    devs: [], build: nil, coreCount: 8, totalMem: 8 * GB, topN: 40)
chk(aggExtBuild.contains { $0.id == 550 && $0.isExternalBuild }, "aggregate: idle external build still shown")
chk(!aggExtBuild.contains { $0.id == 551 }, "aggregate: an equally-light plain process is still filtered (build)")

// External dev servers are exempt from topN too (always shown, like a supervised row).
let manyExternals = (0..<3).map {
    ProcessRow(id: Int32(600 + $0), name: "ext\($0)", cpuPerCore: 0, memBytes: 0, isExternalDev: true)
}
let aggExternalCap = SystemSampler.aggregate(
    rows: manyExternals, devs: [], build: nil, coreCount: 8, totalMem: 8 * GB, topN: 1)
chk(manyExternals.allSatisfy { ext in aggExternalCap.contains { $0.id == ext.id } },
    "aggregate: external dev servers all survive a tight topN")

// A supervised dev row is ALWAYS shown, even when its tree has no live stats this tick.
let aggGhost = SystemSampler.aggregate(
    rows: [], devs: [(id: -7, pids: [999], label: "ghost :3000", isPreview: false)], build: nil,
    coreCount: 8, totalMem: 8 * GB, topN: 40)
chk(aggGhost.contains { $0.id == -7 && $0.cpuPerCore == 0 }, "aggregate: idle dev still shown at 0")

// topN caps only the unsupervised tail; supervised rows always survive the cap.
let manyHeavy = (0..<6).map { ProcessRow(id: Int32(500 + $0), name: "hog\($0)", cpuPerCore: 100, memBytes: GB) }
let aggCap = SystemSampler.aggregate(
    rows: manyHeavy, devs: [(id: -1, pids: [], label: "dev", isPreview: false)], build: nil,
    coreCount: 8, totalMem: 8 * GB, topN: 3)
chk(aggCap.filter { $0.id >= 500 }.count == 3, "aggregate: others capped at topN", "\(aggCap.count) rows")
chk(aggCap.contains { $0.id == -1 }, "aggregate: supervised row survives the cap")

// Others rank by impact (CPU share + mem share): a 4 GB idle process outweighs a 40%-CPU one.
let aggRank = SystemSampler.aggregate(
    rows: [
        ProcessRow(id: 600, name: "midcpu", cpuPerCore: 40, memBytes: 10 * MB),
        ProcessRow(id: 601, name: "bigmem", cpuPerCore: 0, memBytes: 4 * GB),
    ],
    devs: [], build: nil, coreCount: 8, totalMem: 8 * GB, topN: 40)
chk((aggRank.firstIndex { $0.id == 601 } ?? 99) < (aggRank.firstIndex { $0.id == 600 } ?? -1),
    "aggregate: ranked by impact, heaviest first")

// totalMem = 0 (metrics read failed) must not crash the impact math; CPU-heavy rows still surface.
let aggZero = SystemSampler.aggregate(
    rows: [ProcessRow(id: 700, name: "busy", cpuPerCore: 90, memBytes: 100 * MB)],
    devs: [], build: nil, coreCount: 8, totalMem: 0, topN: 40)
chk(aggZero.contains { $0.id == 700 }, "aggregate: totalMem=0 guarded")

// --- runtimeName: bare `node` / `claude` get a real name (args are real ones seen on a dev Mac) ---
func rn(_ comm: String, _ args: String, cwd: String? = nil, owner: String? = nil) -> String? {
    SystemSampler.runtimeName(comm: comm, args: args, cwd: cwd, owner: owner)
}
chk(rn("node", "node /Users/x/Dev/Gallaxxai/PRYCED/app/node_modules/.bin/vue-tsc -b /Users/x/Dev/Gallaxxai/PRYCED/app/.nuxt-check/tsconfig.root.json --noEmit")
    == "PRYCED/app · vue-tsc", "runtime: .bin tool, generic folder 'app' gets its parent")
chk(rn("node", "node /Users/x/Dev/Gallaxxai/PRYCED/app/node_modules/.bin/vitest run --maxWorkers=1 test/a.spec.ts")
    == "PRYCED/app · vitest", "runtime: vitest")
chk(rn("node", "node scripts/check-types.mjs", cwd: "/Users/x/Dev/Gallaxxai/PRYCED/app")
    == "PRYCED/app · check-types", "runtime: script file named, project from cwd")
chk(rn("node", "/Users/x/.local/share/fnm/node-versions/v22/installation/bin/node --experimental-import-meta-resolve --require /Users/x/Dev/Vogels/Owl/node_modules/vitest/suppress-warnings.cjs --conditions node /Users/x/Dev/Vogels/Owl/node_modules/vitest/dist/workers/forks.js")
    == "Owl · vitest", "runtime: flags skipped, package from node_modules")
chk(rn("deliverables.spec.ts", "npm exec vitest run --maxWorkers=1 test/nuxt/deliverables.spec.ts", cwd: "/Users/x/Dev/Gallaxxai/PRYCED/app")
    == "PRYCED/app · vitest", "runtime: npm exec <tool>, title rewritten by npm")
chk(rn("node", "npx -y @modelcontextprotocol/server-filesystem /Users/x") == "@modelcontextprotocol/server-filesystem",
    "runtime: npx scoped package")
chk(rn("node", "node /Users/x/mcp/node_modules/@scope/some-server/dist/index.js", owner: "Claude") == "mcp · some-server",
    "runtime: scoped package under node_modules")
chk(rn("node", "node", cwd: "/Users/x/Dev/Vogels/Owl-Monitor") == "node · Owl-Monitor", "runtime: bare node → cwd project")
chk(rn("node", "node", cwd: "/", owner: "Cursor") == "node (Cursor)", "runtime: bare node, no project → owner app")
chk(rn("node", "node", cwd: nil, owner: nil) == nil, "runtime: nothing to say → nil (caller keeps 'node')")
chk(rn("node", "node -e console.log(1)", cwd: "/") == "inline script", "runtime: node -e")
chk(rn("claude", "claude", cwd: "/Users/x/Dev/Vogels/Owl-Monitor") == "Claude Code · Owl-Monitor", "claude: session named by its project")
chk(rn("claude", "/Users/x/Library/Application Support/Claude/claude-code/2.1.295/abc/claude.app/Contents/MacOS/claude --output-format stream-json", cwd: "/Users/x/Dev/Gallaxxai/PRYCED/app")
    == "Claude Code · PRYCED/app", "claude: desktop session by cwd")
chk(rn("claude", "claude", cwd: NSHomeDirectory()) == nil, "claude: home dir is no project → nil (caller says 'Claude Code')")
chk(rn("Safari", "/Applications/Safari.app/Contents/MacOS/Safari") == nil, "runtime: other programs untouched")
chk(rn("nodemon-ish", "somebinary node_modules") == nil, "runtime: not a runtime → nil")
chk(SystemSampler.projectLabel(fromDirectory: "/Users/x/Dev/Vogels/Owl-Monitor") == "Owl-Monitor", "label: plain folder")
chk(SystemSampler.projectLabel(fromDirectory: "/Users/x/Dev/Site/web") == "Site/web", "label: generic folder + parent")
chk(SystemSampler.projectLabel(fromDirectory: "/") == nil && SystemSampler.projectLabel(fromDirectory: "/tmp") == nil, "label: root and /tmp are no project")
chk(SystemSampler.isClaudeCLI(comm: "claude", args: "claude") && !SystemSampler.isClaudeCLI(comm: "node", args: "node x.js"),
    "claude: CLI detection")

// --- projectName(fromArgs:) — external dev-server labelling ---
chk(SystemSampler.projectName(fromArgs: "node /Users/x/Dev/MiddleSpace/node_modules/.bin/nuxt dev") == "MiddleSpace",
    "projectName: folder before node_modules")
chk(SystemSampler.projectName(fromArgs: "node dist/server.js") == nil, "projectName: no node_modules → nil")
chk(SystemSampler.projectName(fromArgs: "/node_modules/.bin/vite") == nil, "projectName: root node_modules → nil")
chk(SystemSampler.projectName(fromArgs: "/w/App/node_modules/foo/node_modules/.bin/x") == "App",
    "projectName: first node_modules wins")

// --- evaluatePressure ---
let S = 8.0
let G = 1_000_000_000 as UInt64
typealias SS = SystemSampler

var r = SS.evaluatePressure(cpu: 30, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: nil, now: 100*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && !r.justStuck, "pressure: idle stays normal")

r = SS.evaluatePressure(cpu: 95, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: nil, now: 100*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && r.hotSince == 100*G && !r.justStuck, "pressure: hot starts the clock")

r = SS.evaluatePressure(cpu: 95, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 109*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .stuck && r.justStuck && r.reason.contains("CPU"), "pressure: sustained CPU → stuck", r.reason)

r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 95, swapPercent: 70, hotSince: 100*G, now: 110*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .stuck && r.reason.contains("Memory"), "pressure: sustained mem+swap → stuck", r.reason)

r = SS.evaluatePressure(cpu: 95, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 120*G, sustainSeconds: S, current: .stuck)
chk(r.pressure == .stuck && !r.justStuck, "pressure: stays stuck without re-triggering")

r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 130*G, sustainSeconds: S, current: .stuck)
chk(r.pressure == .normal && r.hotSince == nil, "pressure: cools back to normal")

r = SS.evaluatePressure(cpu: 80, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 131*G, sustainSeconds: S, current: .stuck)
chk(r.pressure == .stuck && r.hotSince == 100*G, "pressure: hysteresis band holds state")

r = SS.evaluatePressure(cpu: 95, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 105*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && r.hotSince == 100*G && !r.justStuck, "pressure: hot but not yet sustained stays normal")

r = SS.evaluatePressure(cpu: 95, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 108*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .stuck && r.justStuck, "pressure: exact sustain boundary trips")

r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 95, swapPercent: 20, hotSince: nil, now: 100*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && r.hotSince == nil, "pressure: full memory WITHOUT swap is not hot")

// build CPU is discounted — a build maxing every core must NOT read as a stuck machine.
r = SS.evaluatePressure(cpu: 98, buildCPU: 98, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 120*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && !r.justStuck, "pressure: a build maxing the CPU is not stuck")

// something ELSE pinning the cores (beyond a small build) still trips.
r = SS.evaluatePressure(cpu: 98, buildCPU: 3, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 120*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .stuck && r.justStuck, "pressure: non-build CPU still trips despite the discount")

// build + light other load: the residual is below the bar → normal.
r = SS.evaluatePressure(cpu: 100, buildCPU: 70, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 120*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal, "pressure: build plus light other load stays normal")

// Kernel memory-pressure level (1 normal · 2 warning · 4 critical) beats the used%/swap% guess: an 8 GB
// Mac at 91 % used with leftover swap is NOT stuck while the kernel says normal/warning.
r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 91, swapPercent: 68, hotSince: 100*G, now: 130*G, sustainSeconds: S, current: .normal, memoryLevel: 1)
chk(r.pressure == .normal && !r.justStuck, "pressure: 91% used + 68% swap but kernel level normal → NOT stuck")
r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 91, swapPercent: 68, hotSince: 100*G, now: 130*G, sustainSeconds: S, current: .normal, memoryLevel: 2)
chk(r.pressure == .normal, "pressure: kernel level warning (yellow) → NOT stuck")
r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 70, swapPercent: 10, hotSince: 100*G, now: 130*G, sustainSeconds: S, current: .normal, memoryLevel: 4)
chk(r.pressure == .stuck && r.justStuck && r.reason.contains("critical"), "pressure: kernel level critical, sustained → stuck", r.reason)
r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 70, swapPercent: 10, hotSince: 100*G, now: 105*G, sustainSeconds: S, current: .normal, memoryLevel: 4)
chk(r.pressure == .normal, "pressure: critical but not yet sustained → not stuck")
r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 92, swapPercent: 70, hotSince: 100*G, now: 140*G, sustainSeconds: S, current: .stuck, memoryLevel: 2)
chk(r.pressure == .normal && r.hotSince == nil, "pressure: stuck clears once the kernel drops below critical, even at 92% used")
r = SS.evaluatePressure(cpu: 40, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 140*G, sustainSeconds: S, current: .stuck, memoryLevel: 4)
chk(r.pressure == .stuck, "pressure: still critical → stays stuck")
r = SS.evaluatePressure(cpu: 95, buildCPU: 0, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 120*G, sustainSeconds: S, current: .normal, memoryLevel: 1)
chk(r.pressure == .stuck, "pressure: CPU pinned still trips regardless of memory level")

// --- live off-main sampling (the async collect pass) ---
// Rows + system stats materialize, a supervised leader resolves to its own row via the single
// sid-grouping sweep (this process is the leader), and a dead leader drops out instead of crashing.
let live = SystemSampler()
live.devServerInfo = { [(id: -900, leader: getpid(), label: "suite", isPreview: false),
                        (id: -901, leader: 3_999_999, label: "dead", isPreview: false)] }
live.start()
try? await Task.sleep(for: .seconds(5))   // ≥2 ticks at 2 s
chk(!live.processes.isEmpty, "live: processes populated", "\(live.processes.count) rows")
chk(live.systemMemUsed > 0 && live.totalMem > 0, "live: memory sampled",
    "\(Int(live.systemMemUsed / MB))MB")
chk(live.systemCPU >= 0 && live.systemCPU <= 100, "live: CPU% in range", "\(live.systemCPU)")
chk(live.loadAverage > 0, "live: load average sampled", "\(live.loadAverage)")
let liveDev = live.processes.first { $0.id == -900 }
chk(liveDev != nil && liveDev!.isDevServer && liveDev!.name == "suite",
    "live: supervised row resolved from leader via sid grouping", liveDev?.name ?? "missing")
chk(liveDev.map { $0.memBytes > 0 } ?? false, "live: supervised tree stats non-zero")
chk(!live.processes.contains { $0.id == -901 }, "live: dead leader dropped")

// Timeline history ring buffer: fills after the first (delta-less) tick, ids are monotonic, and
// values fall in sane ranges. At ~2 Hz over 5 s we expect ≥1 point (first tick skipped).
chk(!live.history.isEmpty, "live: history buffer populated", "\(live.history.count) pts")
let ids = live.history.map(\.id)
chk(ids == ids.sorted() && Set(ids).count == ids.count, "live: history ids strictly monotonic", "\(ids)")
chk(live.history.allSatisfy { $0.systemCPU >= 0 && $0.systemCPU <= 100 && $0.memTotal > 0 },
    "live: history points in sane ranges")

print(fail == 0 ? "ALL SAMPLER TESTS PASSED" : "SOME SAMPLER TESTS FAILED")
exit(Int32(fail))
