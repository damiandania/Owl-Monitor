import Foundation

// owl-monitor — CLI client for the Owl Monitor hub (Unix socket).
// Lets any terminal launch/query a dev server through the app.

// A socket client must never die from SIGPIPE when the peer closes mid-write.
signal(SIGPIPE, SIG_IGN)

let dmVersion = "0.1.0"   // keep in sync with project.yml MARKETING_VERSION

let usage = """
owl-monitor — launch, build and supervise dev servers through the Owl Monitor app.

USAGE:
  owl-monitor up [path] [--gb N] [--wait]        Start the server (--wait blocks until ready, prints URL). Alias: run
  owl-monitor preview [path] [--gb N] [--wait]   Serve the production build (needs a `preview`/`start` script)
  owl-monitor build [path]          Build the project (runs alongside the dev server)
  owl-monitor status [--json]       List every known project (name, state, port)
  owl-monitor stop [path] [--all]   Stop one project's server (default: cwd), or --all of them
  owl-monitor stop [path] --force   Close EVERYTHING Owl Monitor runs for the project (server, preview,
                                    worker, build, leftover trees it started) and drop it from the notch
                                    (state "Idle"). Keeps the project (unlike `remove`). Alias: close
  owl-monitor restart [path]        Relaunch the project's server (works from any state)
  owl-monitor remove [path]         Stop and forget the project (aliases: rm, forget)
  owl-monitor logs [path] [-f]      Print (or follow with -f) that project's log (default: cwd)
  owl-monitor logs [path] --build   Print the WHOLE last build's output (the full error, not the tail)
  owl-monitor awake [status] [--json]   Keep-awake (the toolbar cup): is it on, until when
  owl-monitor awake add <minutes>   Add time (off -> on for that long; on -> extends; 1-1440)
  owl-monitor awake off             Let the Mac sleep again
  owl-monitor quota [--json] [--refresh]   Claude and Codex usage windows (what the notch shows)
  owl-monitor version               Print the version (aliases: -v, --version)
  owl-monitor docs                  Print this help

One supervised server PER PROJECT; several projects can run at once. Paths default to the
current directory and are resolved to absolute. The Owl Monitor app hosts the hub at
~/Library/Application Support/OwlMonitor/dm.sock — if it isn't running, it's started for you.

If a build is in progress (this project's OR another's), `up`/`preview` do NOT interrupt it: they
WAIT, keep listening, and start the server automatically once every build finishes — no --wait
needed. `--wait` additionally blocks until the server answers HTTP and prints its URL.
`status --json` includes `building`/`buildElapsed`/`buildETA` so an agent can coordinate.
"""

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"
let rest = Array(args.dropFirst())

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("owl-monitor: \(msg)\n".utf8)); exit(1)
}

/// Exactly one optional path positional; resolved to absolute. More than one is an error.
func singlePath(_ a: DMArgs) -> String {
    if a.positionals.count > 1 { die("too many arguments: \(a.positionals.joined(separator: " "))") }
    if let p = a.positionals.first { return DMParse.absolutePath(p) }
    return FileManager.default.currentDirectoryPath
}

func roundtrip(_ req: IPCRequest) -> [IPCMessage]? {
    let fd = dm_ipc_connect(IPCSocket.path)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    guard var data = try? JSONEncoder().encode(req) else { return nil }
    data.append(0x0A)
    data.withUnsafeBytes { raw in if let b = raw.baseAddress { _ = write(fd, b, raw.count) } }
    var messages: [IPCMessage] = []
    var buffer = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0A {
            if let m = try? JSONDecoder().decode(IPCMessage.self, from: buffer) { messages.append(m) }
            buffer.removeAll()
        } else {
            buffer.append(byte)
        }
    }
    return messages
}

/// Opens the Owl Monitor app via LaunchServices and waits (up to ~15s) for its hub
/// socket to come up. Returns true once the socket accepts a connection.
func launchAppAndWait() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Owl Monitor"]
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    for _ in 0..<75 {                       // 75 × 200ms ≈ 15s (cold first-launch margin)
        let fd = dm_ipc_connect(IPCSocket.path)
        if fd >= 0 { close(fd); return true }
        usleep(200_000)
    }
    return false
}

func requireHub(_ req: IPCRequest) -> [IPCMessage] {
    if let messages = roundtrip(req) { return messages }
    // Hub unreachable — start the app, then retry (the first request right after a
    // cold launch can race the IPC accept loop, so give it a few attempts).
    FileHandle.standardError.write(Data("owl-monitor: starting Owl Monitor…\n".utf8))
    if launchAppAndWait() {
        for _ in 0..<10 {
            if let messages = roundtrip(req) { return messages }
            usleep(300_000)
        }
    }
    FileHandle.standardError.write(Data("owl-monitor: could not reach the Owl Monitor app.\n".utf8))
    exit(1)
}

/// Send a request, print ok messages, exit 1 on error.
func runAndReport(_ req: IPCRequest) {
    for m in requireHub(req) {
        if m.type == "error" {
            FileHandle.standardError.write(Data("owl-monitor: \(m.message ?? "error")\n".utf8)); exit(1)
        }
        print(m.message ?? m.type)
    }
}

/// All known projects, as reported by the hub (used by `status`, `logs` and `--wait`).
func fetchServers() -> [IPCServerInfo] {
    var servers: [IPCServerInfo] = []
    for m in requireHub(IPCRequest(cmd: "status", path: nil, name: nil, gb: nil, all: nil)) where m.type == "status" {
        servers = m.servers ?? []
    }
    return servers
}

/// Start a dev server (`up`) or production preview (`preview`), coordinating with any in-flight
/// build. If the hub reports "busy" (a build is running — starting a server would abort it): without
/// `--wait`, print the guidance and exit non-zero; with `--wait`, block until the build finishes,
/// THEN launch and wait for readiness — so another Claude can queue behind a build instead of
/// killing it. With no conflict, behaves like the old path.
func startServer(cmd: String, path: String, gb: Int?, wait: Bool) {
    var announced = false
    while true {
        let messages = requireHub(IPCRequest(cmd: cmd, path: path, name: nil, gb: gb, all: nil))
        if let busy = messages.first(where: { $0.type == "busy" }) {
            // A build is in progress (this project's or another's). WAIT by default — the caller
            // "keeps listening" — and relaunch once every build clears; no --wait needed. The hub's
            // message explains which build and why. The loop re-checks after the wait so a build that
            // starts in the meantime just defers us again instead of slipping a server in beside it.
            if !announced {
                let note = busy.message ?? "a build is in progress"
                FileHandle.standardError.write(Data("owl-monitor: \(note)\n".utf8))
                announced = true
            }
            waitForBuildsToClear(path)
            usleep(500_000)   // guard: never spin the re-issue loop faster than 2×/s on a hub↔status race
            continue
        }
        for m in messages {
            if m.type == "error" {
                FileHandle.standardError.write(Data("owl-monitor: \(m.message ?? "error")\n".utf8)); exit(1)
            }
            print(m.message ?? m.type)
        }
        if wait { waitUntilReady(path) }
        return
    }
}

/// Block until NO project is building (or the timeout elapses), printing occasional progress to
/// stderr. Used when a launch is deferred behind an in-flight build — this project's OR another's,
/// since a build pauses every dev server for RAM, so we wait for ALL builds to clear before starting
/// the server. Builds can be long (plus OOM heap-retries), so the cap is generous.
func waitForBuildsToClear(_ path: String, timeoutSeconds: Double = 1800) {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var lastNote = -15
    while Date() < deadline {
        let building = fetchServers().filter { $0.building == true }
        if building.isEmpty {
            FileHandle.standardError.write(Data("owl-monitor: build finished — starting the server now…\n".utf8))
            return
        }
        let elapsed = building.compactMap { $0.buildElapsed }.map { Int($0) }.max() ?? 0
        if elapsed >= lastNote + 15 {
            lastNote = elapsed
            let names = building.map { s -> String in
                let e = s.buildElapsed.map { Int($0) } ?? 0
                let eta = s.buildETA.map { " / ~\(Int($0))s" } ?? ""
                return "\(s.name) (\(e)s\(eta))"
            }.sorted().joined(separator: ", ")
            FileHandle.standardError.write(Data("owl-monitor: still building: \(names) — waiting, keep listening…\n".utf8))
        }
        usleep(1_000_000)
    }
    die("timed out after \(Int(timeoutSeconds))s waiting for the build(s) to finish (see: owl-monitor logs '\(path)')")
}

/// Block until the project at `path` is HTTP-ready (print its URL, exit 0), has Failed (print the
/// cause, exit 1), or the timeout elapses — so `up --wait` saves the caller from polling itself.
func waitUntilReady(_ path: String, timeoutSeconds: Double = 180) {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    // A just-issued launch takes a moment to flip the status from a prior "Stopped"/"Idle" (e.g. a
    // rapid stop→up, or launching right after a build that left the session Stopped) to "Launching".
    // So treat "Stopped" as terminal only AFTER we've seen the server go active at least once, or a
    // short grace elapses — otherwise a stale read would abort the wait immediately.
    let stopGraceUntil = Date().addingTimeInterval(5)
    var sawActive = false
    while Date() < deadline {
        // Tolerate a transient untrack/retrack (e.g. a rapid stop→up, or a crash auto-restart): if
        // the project momentarily isn't in the list, keep waiting rather than failing — only `Failed`
        // or the overall timeout ends the wait.
        if let s = fetchServers().first(where: { $0.path == path }) {
            if s.ready == true { print("ready: \(s.url ?? "(running)")"); return }
            if s.state.hasPrefix("Failed") { die("failed: \(s.lastError ?? s.state)") }
            let idleOrStopped = s.state.hasPrefix("Stopped") || s.state.hasPrefix("Idle")
            if !idleOrStopped { sawActive = true }   // Launching / Recycling / Running / …
            // A clean Stop AFTER it was active (or past the launch grace) means something stopped it
            // elsewhere — terminal, don't hang.
            if s.state.hasPrefix("Stopped"), sawActive || Date() > stopGraceUntil {
                die("stopped while waiting (the server was stopped elsewhere)")
            }
        }
        usleep(400_000)
    }
    die("timed out after \(Int(timeoutSeconds))s waiting for readiness (see: owl-monitor logs '\(path)')")
}

switch cmd {
case "run", "up", "preview":
    let a = DMParse.parse(rest, boolFlags: ["--wait"], allowGB: true)
    if let e = a.error { die(e) }
    startServer(cmd: cmd, path: singlePath(a), gb: a.gb, wait: a.flags.contains("--wait"))

case "build", "restart", "remove", "rm", "forget":
    let a = DMParse.parse(rest, boolFlags: [], allowGB: false)
    if let e = a.error { die(e) }
    let normalized = (cmd == "rm" || cmd == "forget") ? "remove" : cmd
    runAndReport(IPCRequest(cmd: normalized, path: singlePath(a), name: nil, gb: nil, all: nil))

case "stop", "close":
    let a = DMParse.parse(rest, boolFlags: ["--all", "--force"], allowGB: false)
    if let e = a.error { die(e) }
    let all = a.flags.contains("--all")
    let force = a.flags.contains("--force") || cmd == "close"
    runAndReport(IPCRequest(cmd: "stop", path: all ? nil : singlePath(a),
                            name: nil, gb: nil, all: all ? true : nil, force: force ? true : nil))

case "status":
    let a = DMParse.parse(rest, boolFlags: ["--json"], allowGB: false)
    if let e = a.error { die(e) }
    let servers = fetchServers()
    if a.flags.contains("--json") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(servers), let s = String(data: data, encoding: .utf8) { print(s) }
        else { print("[]") }
    } else if servers.isEmpty {
        print("No projects yet.")
    } else {
        for s in servers {
            // The state label already carries the port for a running server ("Running · :3999"),
            // so only append the port when the label doesn't already mention it (e.g. a configured
            // port on an idle project).
            let portSuffix = (s.port.map { ":\($0)" }).flatMap { s.state.contains($0) ? nil : "  \($0)" } ?? ""
            print("● \(s.name)  —  \(s.state)\(portSuffix)")
            print("  \(s.path)")
        }
    }

case "awake":
    let a = DMParse.parse(rest, boolFlags: ["--json"], allowGB: false)
    if let e = a.error { die(e) }
    let sub = a.positionals.first ?? "status"
    var minutes: Int?
    switch sub {
    case "status", "off":
        if a.positionals.count > 1 { die("too many arguments: \(a.positionals.dropFirst().joined(separator: " "))") }
    case "add":
        guard a.positionals.count == 2, let m = Int(a.positionals[1]), (1...1440).contains(m) else {
            die("usage: owl-monitor awake add <minutes>   (1-1440)")
        }
        minutes = m
    default:
        die("unknown awake command '\(sub)' (use status, add <minutes>, off)")
    }
    runAndReport(IPCRequest(cmd: "awake", path: nil, name: nil, gb: nil, all: nil,
                            sub: sub, minutes: minutes, json: a.flags.contains("--json") ? true : nil))

case "quota":
    let a = DMParse.parse(rest, boolFlags: ["--json", "--refresh"], allowGB: false)
    if let e = a.error { die(e) }
    if !a.positionals.isEmpty { die("too many arguments: \(a.positionals.joined(separator: " "))") }
    runAndReport(IPCRequest(cmd: "quota", path: nil, name: nil, gb: nil, all: nil,
                            json: a.flags.contains("--json") ? true : nil,
                            refresh: a.flags.contains("--refresh") ? true : nil))

case "logs":
    let a = DMParse.parse(rest, boolFlags: ["-f", "--follow", "--build"], allowGB: false)
    if let e = a.error { die(e) }
    let follow = a.flags.contains("-f") || a.flags.contains("--follow")
    let wantBuild = a.flags.contains("--build")
    let target = singlePath(a)
    guard let server = fetchServers().first(where: { $0.path == target }) else {
        die("no project tracked for \(target) — run 'owl-monitor up' here first")
    }
    // --build reads the last build's full output (BuildRunner mirrors it to its own file); otherwise
    // the dev-server log. The build tail printed by `owl-monitor build` is only a slice of this.
    guard let logPath = wantBuild ? server.buildLogPath : server.logPath else {
        die(wantBuild ? "no build log for \(target) — run 'owl-monitor build' here first"
                      : "no project tracked for \(target) — run 'owl-monitor up' here first")
    }
    if follow {
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-n", "300", "-f", logPath]
        try? tail.run()
        tail.waitUntilExit()
    } else if let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print("(no log yet — launch a server first)")
    }

case "version", "--version", "-v":
    print("owl-monitor \(dmVersion)")

case "docs", "--help", "-h", "help":
    print(usage)

default:
    die("unknown command '\(cmd)'. Try 'owl-monitor --help'.")
}
