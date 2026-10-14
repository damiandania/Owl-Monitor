import Foundation

/// How long a server usually takes to become ready, learned from its last few launches — the ETA behind
/// the launch progress (`launchETA` in `owl-monitor status --json`).
///
/// The MEDIAN of the last `keep` launches, not the last one: a single slow launch (the first after a
/// reboot, or with the machine busy) would make the next one's ETA — and its progress ring — wrong, and
/// one fast one would do the opposite. The median shrugs off a lone outlier. Pure.
enum LaunchTiming {
    /// How many launches are remembered per kind (dev / preview).
    static let keep = 5

    /// `history` with `seconds` appended, oldest dropped past `keep`. Non-positive and non-finite
    /// durations are not measurements and are ignored.
    static func record(_ seconds: TimeInterval, into history: [TimeInterval]) -> [TimeInterval] {
        guard seconds.isFinite, seconds > 0 else { return history }
        return Array((history + [seconds]).suffix(keep))
    }

    /// Where the progress bar stops until the server is really ready. `ready` itself fills the rest, so
    /// a launch that runs longer than expected never shows 100 % while still starting.
    static let progressCap = 0.95

    /// Progress (0...`progressCap`) of a launch that is `elapsed` seconds in, or nil with no ETA.
    ///
    /// Plain elapsed / ETA is the fallback. When a "marker" is known — the moment the server prints its
    /// URL ("Local: http://…", which the app already detects), usually halfway through a long compile —
    /// the bar is split there: up to the marker it runs against the typical time-to-marker and lands on
    /// the fraction of the launch that moment usually represents; after it, against the remaining time.
    /// That follows what the server is actually doing, instead of crawling through a slow compile and then
    /// jumping. `etaMarker` is the typical seconds to the marker, `markerElapsed` when it appeared in
    /// THIS launch (nil until it does).
    static func progress(elapsed: TimeInterval, eta: TimeInterval?, etaMarker: TimeInterval?,
                         markerElapsed: TimeInterval?) -> Double? {
        guard let eta, eta > 0 else { return nil }
        let elapsed = max(0, elapsed)
        guard let etaMarker, etaMarker > 0, etaMarker < eta else {
            return min(progressCap, elapsed / eta)
        }
        let split = etaMarker / eta   // the share of a launch that has passed when the marker appears
        let value: Double
        if let markerElapsed {
            // The remaining part runs against what is typically left after the marker.
            value = split + (1 - split) * min(1, max(0, elapsed - markerElapsed) / (eta - etaMarker))
        } else {
            // Not seen yet: approach the marker's share, but never reach it before it has really appeared.
            value = split * min(0.95, elapsed / etaMarker)
        }
        return min(progressCap, value)
    }

    /// The expected launch time: the median of `history` (the mean of the middle two when even), or nil
    /// with no measurement yet.
    static func eta(_ history: [TimeInterval]) -> TimeInterval? {
        guard !history.isEmpty else { return nil }
        let sorted = history.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
