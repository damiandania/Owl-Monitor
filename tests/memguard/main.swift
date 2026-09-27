import Foundation

// Tests the pure memory-headroom logic: MemoryGuard.launchWarning + swapCrossing. Headless.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let GB = 1_073_741_824.0

// --- launchWarning ---
// Plenty of free RAM, low swap → no warning.
chk(MemoryGuard.launchWarning(heapGB: 4, memUsed: 2 * GB, memTotal: 16 * GB, swapUsed: 0, swapTotal: 4 * GB) == nil,
    "launchWarning: ample headroom → nil")

// Heap bigger than free RAM → warns about the heap.
let tight = MemoryGuard.launchWarning(heapGB: 4, memUsed: 6 * GB, memTotal: 8 * GB, swapUsed: 0, swapTotal: 4 * GB)
chk(tight != nil && tight!.contains("heap"), "launchWarning: heap > free RAM warns", tight ?? "nil")

// High swap alone (heap fits) → warns about swap.
let swampy = MemoryGuard.launchWarning(heapGB: 1, memUsed: 2 * GB, memTotal: 8 * GB, swapUsed: 3.5 * GB, swapTotal: 4 * GB)
chk(swampy != nil && swampy!.contains("swap"), "launchWarning: high swap warns", swampy ?? "nil")

// Both problems → mentions both.
let both = MemoryGuard.launchWarning(heapGB: 8, memUsed: 6 * GB, memTotal: 8 * GB, swapUsed: 3 * GB, swapTotal: 4 * GB)
chk(both != nil && both!.contains("heap") && both!.contains("swap"), "launchWarning: both reasons listed", both ?? "nil")

// No swap device (swapTotal 0) must not divide-by-zero; heap fits → nil.
chk(MemoryGuard.launchWarning(heapGB: 2, memUsed: 2 * GB, memTotal: 8 * GB, swapUsed: 0, swapTotal: 0) == nil,
    "launchWarning: swapTotal=0 guarded")

// --- swapCrossing (edge trigger + hysteresis) ---
var r = MemoryGuard.swapCrossing(swapPercent: 40, wasWarned: false)
chk(r == (false, false), "swap: below threshold, not warned → stays quiet", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 65, wasWarned: false)
chk(r == (true, true), "swap: crossing above threshold → warn once", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 70, wasWarned: true)
chk(r == (false, true), "swap: still high, already warned → no repeat", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 55, wasWarned: true)
chk(r == (false, true), "swap: dipped but within hysteresis → stay armed", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 45, wasWarned: true)
chk(r == (false, false), "swap: dropped below threshold-hysteresis → re-arm", "\(r)")

// --- heap budget (shared RAM between servers) ---
chk(MemoryGuard.reservedGB(systemGB: 8) == 3 && MemoryGuard.reservedGB(systemGB: 16) == 4
    && MemoryGuard.reservedGB(systemGB: 64) == 16, "budget: macOS reserve 3 GB on 8 GB, a quarter above")
func budget(_ learned: Int, floor: Int = 2, ram: Int = 8, others: Int) -> Int {
    MemoryGuard.budgetedHeapGB(learnedGB: learned, floorGB: floor, systemGB: ram, otherServers: others)
}
chk(budget(4, others: 0) == 4, "budget: alone on 8 GB keeps the learned 4 GB", "\(budget(4, others: 0))")
chk(budget(4, others: 1) == 3, "budget: 2 servers on 8 GB → 3 GB each", "\(budget(4, others: 1))")
chk(budget(4, others: 2) == 2, "budget: 3 servers on 8 GB → 2 GB each", "\(budget(4, others: 2))")
chk(budget(4, others: 6) == 2, "budget: never below the floor", "\(budget(4, others: 6))")
chk(budget(4, floor: 4, others: 2) == 4, "budget: a proven floor (past OOM) is respected", "\(budget(4, floor: 4, others: 2))")
chk(budget(6, floor: 6, others: 1) == 6, "budget: an escalated project keeps its level", "\(budget(6, floor: 6, others: 1))")
chk(budget(2, others: 0) == 2, "budget: never RAISES a small learned heap", "\(budget(2, others: 0))")
chk(budget(8, ram: 32, others: 1) == 8, "budget: roomy Mac — 32 GB, 2 servers keep 8 GB", "\(budget(8, ram: 32, others: 1))")
chk(budget(8, ram: 16, others: 2) == 4, "budget: 16 GB, 3 servers → 4 GB each", "\(budget(8, ram: 16, others: 2))")
chk(budget(4, others: -3) == 4, "budget: a bogus negative count is treated as none")

// --- idle ---
let t0 = Date(timeIntervalSince1970: 1_000_000)
chk(!MemoryGuard.isIdle(lastActivity: t0, now: t0.addingTimeInterval(29 * 60), minutes: 30), "idle: 29 of 30 min → not yet")
chk(MemoryGuard.isIdle(lastActivity: t0, now: t0.addingTimeInterval(30 * 60), minutes: 30), "idle: 30 of 30 min → idle")
chk(!MemoryGuard.isIdle(lastActivity: t0, now: t0.addingTimeInterval(999_999), minutes: 0), "idle: 0 minutes = never")

// --- the server's echo of our own health probe is not activity ---
let rootProbe = MemoryGuard.probeEchoPattern(path: "/")
for line in ["15:29:34 [vite] 13:29:34 [200] / 14ms", "[304] /", "GET / 200 in 25ms", "HEAD / 200 - - 3 ms",
             "GET / 404 12.345 ms - 9"] {
    chk(MemoryGuard.isProbeEcho(line, pattern: rootProbe), "probe echo: \(line)")
}
for line in ["[200] /about 5ms", "GET /api/users 200 in 9ms", "✔ Vite server hmr 4 files in 0.9ms",
             "Local: http://localhost:3000/", "POST / 200 in 3ms", ""] {
    chk(!MemoryGuard.isProbeEcho(line, pattern: rootProbe), "not a probe echo: \(line.debugDescription)")
}
let apiProbe = MemoryGuard.probeEchoPattern(path: "/api/health")
chk(MemoryGuard.isProbeEcho("GET /api/health 200 in 2ms", pattern: apiProbe)
    && !MemoryGuard.isProbeEcho("GET /api/healthcheck 200 in 2ms", pattern: apiProbe)
    && !MemoryGuard.isProbeEcho("[200] / 3ms", pattern: apiProbe), "probe echo: custom health path, exact")
chk(!MemoryGuard.isProbeEcho("[200] / 3ms", pattern: nil), "probe echo: no pattern → never")

print(fail == 0 ? "ALL MEMGUARD TESTS PASSED" : "\(fail) MEMGUARD TEST(S) FAILED")
exit(Int32(fail))
