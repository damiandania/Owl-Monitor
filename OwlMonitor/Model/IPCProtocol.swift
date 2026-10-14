import Foundation

/// Shared IPC types between the app (hub) and the `owl-monitor` CLI.
struct IPCRequest: Codable, Sendable {
    var cmd: String          // "run"/"up" | "status" | "stop" | "restart" | "build" | "preview"
    var path: String?        // project path (run/up/build/stop/restart/preview) — defaults to the CLI's cwd
    var name: String?        // reserved
    var gb: Int?             // heap override (run/up: dev heap; preview: build heap)
    var all: Bool?           // stop: stop every supervised server, not just this path's
    var sub: String?         // awake: "status" | "add" | "off"
    var minutes: Int?        // awake add: minutes to add
    var json: Bool?          // awake / quota: reply with JSON instead of a human line
    var refresh: Bool?       // quota: re-read the providers and wait for fresh numbers
    var force: Bool?         // stop: close EVERYTHING for the project (see AppState.forceClose)
}

struct IPCServerInfo: Codable, Sendable {
    var name: String
    var path: String
    var state: String
    var port: Int?
    /// Absolute path to this project's log file (so `owl-monitor logs [path]` can find it).
    var logPath: String?
    /// Absolute path to this project's build log file (so `owl-monitor logs [path] --build` can read
    /// the WHOLE last build's output — the failure tail the CLI prints is only a slice).
    var buildLogPath: String? = nil
    // Structured fields so an agent can operate/diagnose from `status --json` alone — no curl, no
    // reading internal files. All optional for backward/forward compatibility.
    /// HTTP-confirmed running (reliable readiness — true only after a successful health probe).
    var ready: Bool?
    /// The server URL once a port is known, e.g. "http://localhost:3000/".
    var url: String?
    /// Process-group leader pid while running (nil when not running).
    var pid: Int?
    /// Exit code of the last process exit (nil if it has never exited).
    var exitCode: Int?
    /// Human cause of the last failure, with a remedy when known (e.g. an OOM hint).
    var lastError: String?
    // Build coordination — lets an external client (the CLI / another Claude) see that a build is
    // in flight and wait it out instead of interrupting it. All nil when no build is running.
    /// A build is currently running for this project. (Defaults keep older call sites — e.g. the
    /// IPC test — constructing `IPCServerInfo` without the build fields.)
    var building: Bool? = nil
    /// Absolute path of the file the app shows as this project's icon (its favicon), or nil when it has
    /// none and the app falls back to `iconSymbol`.
    var iconPath: String? = nil
    /// SF Symbol the app uses when there is no favicon (the framework's symbol).
    var iconSymbol: String? = nil
    /// While the server is "Launching…": seconds since the launch began, and the expected TOTAL (the median
    /// of the last few launch times to become ready — same meaning as `buildETA`). `launchETA` is nil with no
    /// previous measurement. Both nil in every other state (including "Recycling…").
    var launchElapsed: Double? = nil
    var launchETA: Double? = nil
    /// Ready-made launch progress, 0...0.95 (`ready` fills the rest): elapsed / ETA, split at the moment the
    /// server prints its URL when that is known (see `LaunchTiming.progress`). nil with no ETA.
    var launchProgress: Double? = nil
    /// Seconds since the current build started.
    var buildElapsed: Double? = nil
    /// Expected total build seconds (the last successful build's duration), for an ETA.
    var buildETA: Double? = nil
}

struct IPCMessage: Codable, Sendable {
    var type: String         // "status" | "ok" | "error"
    var servers: [IPCServerInfo]?
    var message: String?
}

enum IPCSocket {
    /// `~/Library/Application Support/OwlMonitor/dm.sock`
    static var path: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/OwlMonitor/dm.sock")
    }
}
