import Foundation

// Tests the Project model: backward-compatible decoding (older projects.json without the auto
// flags), the effective-memory rule, and an encode→decode round trip.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let dec = JSONDecoder()

// Old JSON: no memoryAuto / packageManagerAuto / port → must default to auto.
let oldJSON = """
{"id":"\(UUID().uuidString)","name":"Old","path":"/tmp/x","packageManager":"npm","framework":"nuxt","memoryGB":8}
""".data(using: .utf8)!

guard let old = try? dec.decode(Project.self, from: oldJSON) else {
    print("FAIL model: legacy JSON failed to decode"); exit(1)
}
chk(old.memoryAuto, "model: missing memoryAuto defaults to true")
chk(old.packageManagerAuto, "model: missing packageManagerAuto defaults to true")
chk(old.port == nil, "model: missing port = nil (auto)")

// Round trip preserves the new fields.
let p = Project(name: "RT", path: "/tmp/y", packageManager: .pnpm, framework: .astro,
                memoryGB: 5, memoryAuto: false, port: 4321, packageManagerAuto: false)
guard let data = try? JSONEncoder().encode(p),
      let back = try? dec.decode(Project.self, from: data) else {
    print("FAIL model: round-trip encode/decode failed"); exit(1)
}
chk(back.memoryAuto == false && back.packageManagerAuto == false
    && back.port == 4321 && back.memoryGB == 5,
    "model: round-trip preserves flags / port / memory")

// Effective heap — the deterministic rule behind the OOM fix:
//   auto  → framework default (NOT the stored memoryGB, which may be a stale low value)
//   manual → the explicit memoryGB, floored at minHeapGB
//   always capped at physical RAM.
let nuxtAuto = Project(name: "n", path: "/tmp/n", framework: .nuxt, memoryGB: 1, memoryAuto: true)
chk(nuxtAuto.effectiveMemoryGB(systemGB: 64) == HeapScaling.firstGB,
    "effective: auto starts at firstGB, ignores stale memoryGB=1", "\(nuxtAuto.effectiveMemoryGB(systemGB: 64))")
let nodeAuto = Project(name: "x", path: "/tmp/x", framework: .node, memoryAuto: true)
chk(nodeAuto.effectiveMemoryGB(systemGB: 64) == HeapScaling.firstGB, "effective: auto node → firstGB")
let manual = Project(name: "m", path: "/tmp/m", framework: .nuxt, memoryGB: 6, memoryAuto: false)
chk(manual.effectiveMemoryGB(systemGB: 64) == 6, "effective: manual respects memoryGB=6")
let lowManual = Project(name: "l", path: "/tmp/l", framework: .node, memoryGB: 1, memoryAuto: false)
chk(lowManual.effectiveMemoryGB(systemGB: 64) == Project.minHeapGB, "effective: manual floored at minHeapGB")
chk(nuxtAuto.effectiveMemoryGB(systemGB: 4) == 4, "effective: capped at system RAM (4)")

// Per-project log path: stable, ends in .log, unique per id.
let lp1 = Project(name: "Foo Bar", path: "/tmp/a", framework: .node)
let lp2 = Project(name: "Foo Bar", path: "/tmp/b", framework: .node)
chk(lp1.logFileURL.lastPathComponent.hasSuffix(".log"), "log: ends in .log", lp1.logFileURL.lastPathComponent)
chk(lp1.logFileURL == lp1.logFileURL, "log: stable for a project")
chk(lp1.logFileURL != lp2.logFileURL, "log: distinct per project (different id)")

// AppSettings: empty JSON → defaults; round trip preserves values.
guard let defs = try? dec.decode(AppSettings.self, from: "{}".data(using: .utf8)!) else {
    print("FAIL model: AppSettings '{}' failed to decode"); exit(1)
}
chk(defs.browser == nil, "settings: default browser = system default (nil)")
chk(defs.analysisModel == AppSettings.defaultModel, "settings: default model = haiku", defs.analysisModel)
chk(defs.autoCloseOrphans, "settings: auto-close orphans on by default")
chk(defs.defaultMemoryGB == 4, "settings: default heap 4")
chk(defs.editor == nil, "settings: default editor = first found (nil)")
chk(defs.bars == AppSettings.defaultBars, "settings: default bars = cpu/memory/swap")
chk(defs.notificationsEnabled, "settings: notifications enabled by default")
chk(defs.notifyFailures && defs.notifyRecovery && defs.notifyBuilds && defs.notifyPressure,
    "settings: all notification categories on by default")

let custom = AppSettings(browser: "Firefox", analysisModel: "claude-opus-5-5",
                         autoCloseOrphans: false, defaultMemoryGB: 8,
                         notificationsEnabled: false, notifyFailures: false, notifyPressure: false)
guard let sData = try? JSONEncoder().encode(custom),
      let sBack = try? dec.decode(AppSettings.self, from: sData) else {
    print("FAIL model: AppSettings round-trip failed"); exit(1)
}
chk(sBack == custom, "settings: round-trip preserves all fields")

// Retired model IDs (settings saved by an older build) move to the current model of the same tier —
// otherwise the picker shows nothing and every `claude --model` call fails.
func savedModel(_ id: String) -> String {
    let json = "{\"analysisModel\":\"\(id)\"}".data(using: .utf8)!
    return (try? dec.decode(AppSettings.self, from: json))?.analysisModel ?? "<decode failed>"
}
let tierID = { (tier: String) in AppSettings.models.first { $0.id.contains(tier) }!.id }
chk(savedModel("claude-sonnet-4-6") == tierID("sonnet"), "settings: stale sonnet → current sonnet", savedModel("claude-sonnet-4-6"))
chk(savedModel("claude-opus-4-8") == tierID("opus"), "settings: stale opus → current opus", savedModel("claude-opus-4-8"))
chk(savedModel("claude-haiku-4-5") == tierID("haiku"), "settings: undated haiku → dated haiku", savedModel("claude-haiku-4-5"))
chk(savedModel("gpt-4") == AppSettings.defaultModel, "settings: unknown model → default")
chk(savedModel("") == AppSettings.defaultModel, "settings: empty model → default")
for m in AppSettings.models {
    chk(savedModel(m.id) == m.id, "settings: current model kept as-is (\(m.id))")
}

// ── Project.effectiveHealthPath: defaults to "/", normalizes a leading slash (A6). ──
chk(Project(name: "h", path: "/tmp/h").effectiveHealthPath == "/", "health: unset → /")
chk(Project(name: "h", path: "/tmp/h", healthPath: "health").effectiveHealthPath == "/health",
    "health: bare 'health' → /health")
chk(Project(name: "h", path: "/tmp/h", healthPath: "/api/health").effectiveHealthPath == "/api/health",
    "health: absolute path preserved")
chk(Project(name: "h", path: "/tmp/h", healthPath: "  ").effectiveHealthPath == "/", "health: blank → /")

// ── HeapScaling.next: ladder climbs past 8 GB but is clamped to physical RAM (A2). ──
chk(HeapScaling.next(after: 4, systemGB: 8) == 6, "heap: 4→6 on 8 GB")
chk(HeapScaling.next(after: 6, systemGB: 8) == 8, "heap: 6→8 on 8 GB")
chk(HeapScaling.next(after: 8, systemGB: 8) == nil, "heap: 8→nil on 8 GB (RAM-capped, unchanged)")
chk(HeapScaling.next(after: 8, systemGB: 32) == 12, "heap: 8→12 on 32 GB (no longer stuck at 8)")
chk(HeapScaling.next(after: 12, systemGB: 16) == 16, "heap: 12→16 on 16 GB")
chk(HeapScaling.next(after: 16, systemGB: 16) == nil, "heap: 16→nil on 16 GB (RAM-capped)")
chk(HeapScaling.next(after: 16, systemGB: 64) == 24, "heap: 16→24 on 64 GB")
chk(HeapScaling.next(after: 24, systemGB: 64) == nil, "heap: 24 is the top of the ladder")

// ── HeapScaling.looksLikeOOM: fewer false positives (A3). ───────────────────────
chk(HeapScaling.looksLikeOOM(logLines: [], exitCode: 6), "oom: exit 6 → OOM")
chk(!HeapScaling.looksLikeOOM(logLines: ["JavaScript heap out of memory"], exitCode: 0),
    "oom: clean exit 0 is never OOM even if log mentions heap")
chk(HeapScaling.looksLikeOOM(logLines: ["FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory"],
                             exitCode: 134), "oom: real V8 OOM line → OOM")
chk(!HeapScaling.looksLikeOOM(logLines: ["error: memory allocation failed for buffer"], exitCode: 1),
    "oom: lone 'allocation failed' (no fatal/heap marker) is not OOM")
chk(HeapScaling.looksLikeOOM(logLines: ["FATAL ERROR: something", "Allocation failed"], exitCode: 1),
    "oom: 'allocation failed' + 'fatal error' → OOM")
chk(!HeapScaling.looksLikeOOM(logLines: ["compiled the heap snapshot successfully"], exitCode: 1),
    "oom: unrelated 'heap' mention is not OOM")

// ── JSONFileStore: corruption safety (A1) — must never silently lose data. ──────
MainActor.assumeIsolated {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dm-jsonstore-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Absent file → .missing (genuine first run, NOT corruption → caller uses defaults quietly).
    let s1 = JSONFileStore<[Project]>(filename: "projects.json", version: 1, directory: tmp)
    if case .missing = s1.load() { chk(true, "store: absent file → .missing") }
    else { chk(false, "store: absent file → .missing") }

    // Round trip through the versioned envelope.
    s1.save([Project(name: "A", path: "/tmp/a"), Project(name: "B", path: "/tmp/b")])
    if case .loaded(let back) = s1.load(), back.map(\.name) == ["A", "B"] {
        chk(true, "store: versioned round trip")
    } else { chk(false, "store: versioned round trip") }

    // Legacy un-enveloped file (a bare array written before versioning) still loads.
    let legacyURL = tmp.appendingPathComponent("legacy.json")
    try? JSONEncoder().encode([Project(name: "Old", path: "/tmp/o")]).write(to: legacyURL)
    let s2 = JSONFileStore<[Project]>(filename: "legacy.json", version: 1, directory: tmp)
    if case .loaded(let back) = s2.load(), back.first?.name == "Old" {
        chk(true, "store: legacy bare-array file still loads")
    } else { chk(false, "store: legacy bare-array file still loads") }

    // Corrupt file → .corrupt with a preserved backup; the original is moved aside, NOT clobbered.
    let corruptURL = tmp.appendingPathComponent("corrupt.json")
    try? Data("{ this is not valid json".utf8).write(to: corruptURL)
    let s3 = JSONFileStore<[Project]>(filename: "corrupt.json", version: 1, directory: tmp)
    if case .corrupt(let backup) = s3.load() {
        chk(backup != nil, "store: corrupt file reported with a backup path")
        chk(backup.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            "store: corrupt file preserved on disk (recoverable)")
        chk(!FileManager.default.fileExists(atPath: corruptURL.path),
            "store: corrupt original moved aside (next save won't clobber the backup)")
    } else { chk(false, "store: corrupt file → .corrupt") }

    // Same safety for the settings payload type.
    let setURL = tmp.appendingPathComponent("settings.json")
    try? Data("not json at all".utf8).write(to: setURL)
    let s4 = JSONFileStore<AppSettings>(filename: "settings.json", version: 1, directory: tmp)
    if case .corrupt = s4.load() { chk(true, "store: corrupt settings → .corrupt") }
    else { chk(false, "store: corrupt settings → .corrupt") }
}

print(fail == 0 ? "ALL MODEL TESTS PASSED" : "SOME MODEL TESTS FAILED")
exit(Int32(fail))
