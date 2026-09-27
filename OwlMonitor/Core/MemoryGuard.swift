import Foundation

/// Pure memory-headroom checks for a RAM-constrained Mac (the whole reason this app exists).
/// Framework-free and `nonisolated` so it's unit-testable headless, like `SystemSampler.aggregate`.
enum MemoryGuard {
    /// Swap fill (%) at/above which we consider the machine memory-stressed — lower than the
    /// pressure state-machine's stuck threshold, so we can warn BEFORE it's actually thrashing.
    static let highSwapThreshold: Double = 60

    private static let gb = 1_073_741_824.0

    /// A human warning when starting a process that will claim `heapGB` is risky given the current
    /// memory state — nil when there's enough headroom. Risky when the heap won't fit in free
    /// physical RAM, or swap is already high. Used to warn (not block) before a launch.
    static func launchWarning(heapGB: Int, memUsed: Double, memTotal: Double,
                              swapUsed: Double, swapTotal: Double) -> String? {
        let freeBytes = max(0, memTotal - memUsed)
        let heapBytes = Double(heapGB) * gb
        let swapPct = swapTotal > 0 ? swapUsed / swapTotal * 100 : 0
        var reasons: [String] = []
        if heapBytes > freeBytes {
            reasons.append(String(format: "its %d GB heap exceeds the ~%.1f GB of free RAM", heapGB, freeBytes / gb))
        }
        if swapPct >= highSwapThreshold {
            reasons.append("swap is already \(Int(swapPct))% full")
        }
        guard !reasons.isEmpty else { return nil }
        return reasons.joined(separator: ", and ")
            + " — starting it may cause heavy swapping. Consider closing idle projects or lowering its heap."
    }

    // MARK: - Heap budget

    /// RAM (GB) left for macOS and your other apps (browser, editor) before any Node heap is handed
    /// out: 3 GB on an 8 GB Mac, a quarter of RAM on bigger ones.
    static func reservedGB(systemGB: Int) -> Int { max(3, systemGB / 4) }

    /// The heap ceiling (GB) for a server launched while `otherServers` others already run.
    ///
    /// `--max-old-space-size` is a ceiling, not a reservation — but V8 lets a heap grow lazily all the
    /// way up to it before collecting hard. Three servers at the usual 4 GB add up to 12 GB of
    /// ceilings on an 8 GB Mac, so macOS starts swapping long before any of them feels pressure.
    /// Splitting what's left after `reservedGB` evenly keeps their sum inside physical RAM, which
    /// makes each V8 collect earlier and stay lean instead.
    ///
    /// Only ever LOWERS the heap: never above `learnedGB` (what the project would get on its own),
    /// never below `floorGB` (what it has proven it needs — an out-of-memory escalation raises it).
    /// Rounded to the nearest GB, so two servers on 8 GB get 3 GB each, three get 2.
    static func budgetedHeapGB(learnedGB: Int, floorGB: Int, systemGB: Int, otherServers: Int) -> Int {
        let budget = max(0, systemGB - reservedGB(systemGB: systemGB))
        let share = Int((Double(budget) / Double(max(0, otherServers) + 1)).rounded())
        return max(floorGB, min(learnedGB, share))
    }

    // MARK: - Idle

    /// Whether a server has been idle long enough to stop: `lastActivity` (its last accepted
    /// connection, log output or launch) is at least `minutes` before `now`. `minutes <= 0` = never.
    static func isIdle(lastActivity: Date, now: Date, minutes: Int) -> Bool {
        minutes > 0 && now.timeIntervalSince(lastActivity) >= Double(minutes) * 60
    }

    /// Matches the access-log line a server prints for a request to `path` — above all Owl Monitor's
    /// OWN health probe, which Astro echoes every few seconds (`[200] / 14ms`) and which must not
    /// count as someone using the server, or it would never go idle. Covers Astro/Vite
    /// (`[200] /`), Next (`GET / 200 in 25ms`), Remix and morgan (`GET / 200 - 3 ms`, `HEAD / 200`).
    /// The path must end there, so `/about` never matches a probe of `/`. A real visit to `path`
    /// isn't lost by skipping its line: the visitor's connection counts on its own.
    static func probeEchoPattern(path: String) -> NSRegularExpression? {
        let p = NSRegularExpression.escapedPattern(for: path)
        return try? NSRegularExpression(
            pattern: #"(\[\s*[1-5]\d\d\s*\]\s+PATH(\s|$))|(\b(GET|HEAD)\s+PATH\s+[1-5]\d\d\b)"#
                .replacingOccurrences(of: "PATH", with: p))
    }

    /// Whether `line` (ANSI already stripped) is only the echo of a request to the probe path.
    static func isProbeEcho(_ line: String, pattern: NSRegularExpression?) -> Bool {
        guard let pattern else { return false }
        return pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Edge-trigger for the standalone high-swap warning: given the previous "warned" flag and the
    /// current swap %, returns whether to warn now and the new flag. Warns once when crossing ABOVE
    /// `highSwapThreshold`; re-arms only after dropping below it minus `hysteresis` (so it doesn't
    /// flap around the threshold). Pure so the crossing logic is testable without a run loop.
    static func swapCrossing(swapPercent: Double, wasWarned: Bool, hysteresis: Double = 10)
        -> (warn: Bool, warned: Bool) {
        if !wasWarned, swapPercent >= highSwapThreshold { return (true, true) }
        if wasWarned, swapPercent < highSwapThreshold - hysteresis { return (false, false) }
        return (false, wasWarned)
    }
}
