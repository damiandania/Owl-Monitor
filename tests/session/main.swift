import Foundation

@MainActor
func runSessionTests() async -> Int {
    var failures = 0
    func check(_ label: String, _ cond: Bool, _ detail: String = "") {
        print((cond ? "PASS " : "FAIL ") + label + (detail.isEmpty ? "" : " — " + detail))
        if !cond { failures += 1 }
    }

    // Real HTTP server so warm-up → running (via the first HTTP probe) is exercised —
    // this is the regression test for the recycle-during-warm-up loop.
    let project = Project(
        name: "fake", path: "/tmp",
        devCommand: "node -e 'require(\"http\").createServer((q,r)=>r.end(\"ok\")).listen(4321,\"127.0.0.1\",()=>console.log(\"Local: http://localhost:4321/\"))'",
        memoryGB: 2
    )
    let session = DevSession(project: project)
    session.start(memoryGB: 2)

    try? await Task.sleep(for: .seconds(5))

    check("port parsed", session.detectedPort == 4321, "port=\(String(describing: session.detectedPort))")
    let running: Bool = { if case .running = session.state { return true }; return false }()
    check("reached running via HTTP", running, "state=\(session.state.label)")
    check("isReady true once running", session.isReady, "ready=\(session.isReady)")
    check("url reported", session.url == "http://localhost:4321/", "url=\(session.url ?? "nil")")
    check("no lastError while healthy", session.lastError == nil, "err=\(session.lastError ?? "nil")")
    check("log captured", session.logLines.contains { $0.contains("4321") })
    check("NODE_OPTIONS injected", session.logLines.contains { $0.contains("max-old-space-size=2048") })
    check("no shell noise in log", !session.logLines.contains { $0.contains("Restored session") })

    // Stop should kill the tree; state becomes stopped/failed shortly after.
    session.stop()
    try? await Task.sleep(for: .seconds(3))
    let stopped: Bool = { switch session.state { case .stopped, .failed: return true; default: return false } }()
    check("stopped after stop()", stopped, "state=\(session.state.label)")
    check("isReady false after stop", !session.isReady, "ready=\(session.isReady)")

    // Failure diagnostics (agent-operability): a server that exits non-zero records the exit code and
    // a human-readable lastError, so `status --json` can diagnose without reading internal files.
    let failProj = Project(name: "failx", path: "/tmp",
        devCommand: "sh -c 'echo starting; exit 5'", memoryGB: 2)
    let failSession = DevSession(project: failProj)
    failSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(3))
    let didFail: Bool = { if case .failed = failSession.state { return true }; return false }()
    check("fail: reached Failed", didFail, "state=\(failSession.state.label)")
    check("fail: exitCode recorded", failSession.lastExitCode == 5, "code=\(String(describing: failSession.lastExitCode))")
    check("fail: lastError mentions code", (failSession.lastError ?? "").contains("code 5"), "err=\(failSession.lastError ?? "nil")")

    // Crash auto-revive: a server that WAS healthy then has its process killed externally must
    // relaunch itself (bounded backoff), not stay dead. Regression test for the #10 auto-revive.
    let reviveProj = Project(name: "revive", path: "/tmp",
        devCommand: "node -e 'require(\"http\").createServer((q,r)=>r.end(\"ok\")).listen(4322,\"127.0.0.1\",()=>console.log(\"Local: http://localhost:4322/\"))'",
        memoryGB: 2)
    let reviveSession = DevSession(project: reviveProj)
    reviveSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(4))      // let it become healthy
    let healthyPid = reviveSession.pid
    check("revive: ready before kill", reviveSession.isReady, "state=\(reviveSession.state.label)")
    kill(healthyPid, SIGKILL)                    // simulate an external crash of the dev process
    try? await Task.sleep(for: .seconds(6))      // exit + backoff (~1s) + relaunch + warm-up
    let revivedActive = reviveSession.state.isActive
    let revivedPid = reviveSession.pid
    check("revive: active again after external kill", revivedActive, "state=\(reviveSession.state.label)")
    check("revive: relaunched with a fresh pid", revivedPid > 0 && revivedPid != healthyPid,
          "before=\(healthyPid) after=\(revivedPid)")
    reviveSession.stop()
    try? await Task.sleep(for: .seconds(2.6))

    // Metrics sampling on a CPU-bound child.
    let cpuProject = Project(name: "cpu", path: "/tmp", devCommand: "yes > /dev/null", memoryGB: 2)
    let cpuSession = DevSession(project: cpuProject)
    cpuSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(2.6))
    let samples = cpuSession.history.count
    let maxTreeCPU = cpuSession.history.map(\.treeCPU).max() ?? 0
    let lastMem = cpuSession.history.last?.treeMem ?? 0
    let sysMem = cpuSession.history.last?.systemMemTotal ?? 0
    check("metrics: sampler runs", samples >= 2, "samples=\(samples)")
    check("metrics: treeCPU detected", maxTreeCPU > 10, String(format: "max %.0f%%", maxTreeCPU))
    check("metrics: treeMem > 0", lastMem > 0, "\(Int(lastMem / 1_048_576))MB")
    check("metrics: systemMem read", sysMem > 1_000_000_000, "\(Int(sysMem / 1_048_576))MB")
    cpuSession.stop()
    try? await Task.sleep(for: .seconds(2.6))

    // P3: recycle() kills the tree and relaunches with a fresh pid.
    let recProject = Project(
        name: "rec", path: "/tmp",
        devCommand: "sh -c 'echo \"Local: http://localhost:4399/\"; sleep 30'",
        memoryGB: 2
    )
    let recSession = DevSession(project: recProject)
    recSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(1.5))
    let pidBefore = recSession.pid
    check("recycle: active before", recSession.state.isActive && pidBefore > 0, "pid=\(pidBefore)")
    recSession.recycle()
    try? await Task.sleep(for: .seconds(3.0))  // SIGTERM + 0.4s + relaunch + grace
    let pidAfter = recSession.pid
    check("recycle: count incremented", recSession.recycleCount == 1, "count=\(recSession.recycleCount)")
    check("recycle: fresh pid", pidAfter > 0 && pidAfter != pidBefore, "before=\(pidBefore) after=\(pidAfter)")
    check("recycle: active again", recSession.state.isActive, "state=\(recSession.state.label)")
    recSession.stop()
    try? await Task.sleep(for: .seconds(2.6))

    // P5: build runner — success and failure.
    let okBuild = BuildRunner(project: Project(name: "b", path: "/tmp",
        buildCommand: "sh -c 'echo BUILDING_OK; exit 0'"))
    okBuild.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(2))
    check("build: success", okBuild.result == 0 && !okBuild.isRunning, "result=\(String(describing: okBuild.result))")
    check("build: log captured", okBuild.logLines.contains { $0.contains("BUILDING_OK") })

    let failBuild = BuildRunner(project: Project(name: "bf", path: "/tmp",
        buildCommand: "sh -c 'exit 3'"))
    var failEvented = false
    failBuild.onEvent = { _ in failEvented = true }
    failBuild.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(2))
    check("build: failure code", failBuild.result == 3, "result=\(String(describing: failBuild.result))")
    check("build: failure posts a buildFinished event", failEvented, "evented=\(failEvented)")

    // P6: a user-initiated stop() must NOT post a buildFinished event — the process is signal-killed
    // (non-zero exit), but the user cancelled deliberately, so it isn't a "Build failed". onFinish
    // still fires so the orchestrator can relaunch the dev server it paused.
    let stopBuild = BuildRunner(project: Project(name: "bs", path: "/tmp",
        buildCommand: "sh -c 'sleep 10'"))
    var stopEvented = false
    var stopFinished = false
    stopBuild.onEvent = { _ in stopEvented = true }
    stopBuild.onFinish = { _ in stopFinished = true }
    stopBuild.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(0.5))
    stopBuild.stop()
    try? await Task.sleep(for: .seconds(2))
    check("build: stop() posts no buildFinished event", !stopEvented, "evented=\(stopEvented)")
    check("build: stop() still calls onFinish", stopFinished, "finished=\(stopFinished)")
    check("build: stop() logs 'build stopped'", stopBuild.logLines.contains { $0.contains("build stopped") })

    // Framework env: Astro 7 must be forced to the foreground (it auto-daemonizes under an AI agent),
    // Nuxt keeps its lock-ignore, everything else gets no extra env.
    check("env: astro forces foreground", DevSession.frameworkEnv(for: .astro).contains("ASTRO_DEV_BACKGROUND=0"))
    check("env: nuxt ignores its dev lock", DevSession.frameworkEnv(for: .nuxt).contains("NUXT_IGNORE_LOCK=1"))
    check("env: vite gets no extra env", DevSession.frameworkEnv(for: .vite).isEmpty)

    // C3: log search filter — case-insensitive, ANSI-stripped, empty query = everything.
    let logLines = ["\u{1B}[31mERROR boom\u{1B}[0m", "info: started", "warn: slow"]
    check("logfilter: empty query keeps all", LogFilter.filter(logLines, query: "").count == 3)
    check("logfilter: case-insensitive substring", LogFilter.filter(logLines, query: "error") == [logLines[0]])
    check("logfilter: matches stripped of ANSI", LogFilter.matches("\u{1B}[31mboom\u{1B}[0m", query: "boom"))
    check("logfilter: no match", LogFilter.filter(logLines, query: "zzz").isEmpty)

    // C4: LineBuffer — reassembly of partial lines across chunks, exactly as process output arrives.
    var lb = LineBuffer()
    check("linebuffer: holds a partial line", lb.ingest(Data("ab".utf8)).isEmpty)
    check("linebuffer: completes across chunks", lb.ingest(Data("c\ndef\ng".utf8)) == ["abc", "def"])
    check("linebuffer: flushes the held tail next", lb.ingest(Data("h\n".utf8)) == ["gh"])
    check("linebuffer: empty lines preserved", lb.ingest(Data("\n\nx\n".utf8)) == ["", "", "x"])
    var lbReset = LineBuffer()
    _ = lbReset.ingest(Data("partial".utf8))
    lbReset.reset()
    check("linebuffer: reset drops the partial", lbReset.ingest(Data("done\n".utf8)) == ["done"])
    var lbBad = LineBuffer()
    check("linebuffer: invalid UTF-8 chunk dropped", lbBad.ingest(Data([0xFF, 0xFE, 0x0A])).isEmpty)

    // C5: ANSI parsing — content preserved, styles applied, and the parse cache returns stable
    // results (the second call for the same line is served from the cache).
    let colored = "\u{1B}[31mred\u{1B}[0m plain \u{1B}[1mbold\u{1B}[22m"
    let a1 = ANSI.attributed(colored)
    let a2 = ANSI.attributed(colored)
    check("ansi: characters preserved", String(a1.characters) == "red plain bold",
          String(a1.characters))
    check("ansi: cached result identical", a1 == a2)
    check("ansi: a run carries the colour", a1.runs.contains { $0.foregroundColor != nil })
    check("ansi: bold run marked", a1.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    check("ansi: plain passthrough", String(ANSI.attributed("hello").characters) == "hello")
    check("ansi: unterminated escape doesn't crash",
          String(ANSI.attributed("\u{1B}[31").characters).isEmpty)
    check("ansi: strippedANSI", "\u{1B}[1;32mok\u{1B}[0m".strippedANSI == "ok")

    // C6: log trim (chunked, with slack) — a 5000-line build stays within maxLogLines(4000)+slack,
    // drops the OLDEST lines (the "$ command" header is long gone) and keeps the tail intact.
    let bigBuild = BuildRunner(project: Project(name: "big", path: "/tmp",
        buildCommand: "sh -c 'seq 1 5000; exit 0'"))
    bigBuild.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(3))
    check("trim: build finished", bigBuild.result == 0, "result=\(String(describing: bigBuild.result))")
    check("trim: count within cap+slack",
          bigBuild.logLines.count >= 4000 && bigBuild.logLines.count <= 4201,
          "count=\(bigBuild.logLines.count)")
    check("trim: oldest lines dropped", bigBuild.logLines.first?.hasPrefix("$") == false,
          "first=\(bigBuild.logLines.first ?? "nil")")
    check("trim: tail intact", bigBuild.logLines.contains { $0 == "5000" })
    check("trim: finish line appended", bigBuild.logLines.last?.contains("build finished") == true)

    // C7: dev-session trim — same chunked-slack behaviour on the server log path (cap 2000).
    let spamSession = DevSession(project: Project(name: "spam", path: "/tmp",
        devCommand: "sh -c 'seq 1 5000; sleep 30'", memoryGB: 2))
    spamSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(3))
    check("trim: dev log within cap+slack",
          spamSession.logLines.count >= 2000 && spamSession.logLines.count <= 2200,
          "count=\(spamSession.logLines.count)")
    check("trim: dev tail intact", spamSession.logLines.contains { $0 == "5000" })
    spamSession.stop()
    try? await Task.sleep(for: .seconds(2.6))

    // C8: worker runner — run, stdin round-trip, deliberate stop (≠ crash), and a crash exit code.
    let okWorker = WorkerRunner(project: Project(name: "w", path: "/tmp",
        workerCommand: "sh -c 'echo W_OK; read line; echo GOT_$line; sleep 20'"))
    okWorker.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(1.5))
    check("worker: running", okWorker.isRunning)
    check("worker: log captured", okWorker.logLines.contains { $0.contains("W_OK") })
    okWorker.sendInput("ping")
    try? await Task.sleep(for: .seconds(1))
    check("worker: stdin echoed back", okWorker.logLines.contains { $0.contains("GOT_ping") })
    check("worker: input logged", okWorker.logLines.contains { $0.contains("> ping") })
    okWorker.stop()
    try? await Task.sleep(for: .seconds(3))
    check("worker: stopped", !okWorker.isRunning)
    check("worker: deliberate stop is not a crash", !okWorker.didCrash)
    check("worker: 'worker stopped' logged", okWorker.logLines.contains { $0 == "worker stopped" })

    let crashWorker = WorkerRunner(project: Project(name: "wc", path: "/tmp",
        workerCommand: "sh -c 'echo boom; exit 7'"))
    crashWorker.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(2))
    check("worker: crash flagged", crashWorker.didCrash)
    check("worker: crash exit code", crashWorker.lastExitCode == 7,
          "code=\(String(describing: crashWorker.lastExitCode))")
    check("worker: crash logged", crashWorker.logLines.contains { $0.contains("worker crashed (code 7)") })

    // C9: env-var injection — ProcessSupport.envAssignments builds shell-safe inline assignments.
    check("env: empty → no prefix", ProcessSupport.envAssignments([]).isEmpty)
    let simple = ProcessSupport.envAssignments([.init(key: "API_URL", value: "http://x")])
    check("env: single pair + trailing space", simple == "API_URL='http://x' ", "[\(simple)]")
    let multi = ProcessSupport.envAssignments([.init(key: "A", value: "1"), .init(key: "B", value: "2")])
    check("env: ordered, space-separated", multi == "A='1' B='2' ", "[\(multi)]")
    let spaces = ProcessSupport.envAssignments([.init(key: "MSG", value: "hello world")])
    check("env: value with spaces stays one token (quoted)", spaces == "MSG='hello world' ", "[\(spaces)]")
    let quoted = ProcessSupport.envAssignments([.init(key: "Q", value: "a'b")])
    check("env: embedded single-quote escaped", quoted == "Q='a'\\''b' ", "[\(quoted)]")
    let dollar = ProcessSupport.envAssignments([.init(key: "P", value: "$HOME/x")])
    check("env: dollar not expanded (single-quoted)", dollar == "P='$HOME/x' ", "[\(dollar)]")
    let skip = ProcessSupport.envAssignments([.init(key: "  ", value: "v"), .init(key: "OK", value: "y")])
    check("env: blank keys skipped", skip == "OK='y' ", "[\(skip)]")

    // A4: reapLeftovers matches a project path by boundary, not substring — a project at /p/foo must
    // never reap a sibling server at /p/foobar.
    check("path: exact arg match", DevSession.args("node /p/foo/server.js", referencePath: "/p/foo"))
    check("path: trailing match", DevSession.args("cd /p/foo", referencePath: "/p/foo"))
    check("path: sibling NOT matched", !DevSession.args("node /p/foobar/server.js", referencePath: "/p/foo"))
    check("path: longer-name NOT matched", !DevSession.args("/p/foobar", referencePath: "/p/foo"))

    // A5: fullTree enumerates the whole tree (leader + children) and the tree-kill reaps all of it,
    // including children that live in their own process group (the setsid-escapee case the old
    // killpg-only path missed).
    if let proc = SpawnedProcess.spawn(command: "sh -c 'sleep 30 & sleep 30 & wait'",
                                       cwd: "/tmp", wantsStdin: false) {
        try? await Task.sleep(for: .seconds(1.0))
        let tree = ProcessTree.fullTree(of: proc.pid)
        check("tree: fullTree includes leader + children", tree.count >= 3, "count=\(tree.count)")
        let members = ProcessTree.sessionMembers(of: proc.pid)
        check("tree: sessionMembers includes the leader", members.contains(proc.pid), "n=\(members.count)")
        check("tree: sessionMembers of a dead pid is just itself", ProcessTree.sessionMembers(of: 3_999_999) == [3_999_999])
        check("tree: sessionMembers of pid ≤ 0 is empty", ProcessTree.sessionMembers(of: 0).isEmpty)
        ProcessSupport.gracefulKillTree(proc.pid)
        try? await Task.sleep(for: .seconds(3.5))   // SIGTERM + 2s grace + SIGKILL + reap
        let aliveAfter = tree.filter { kill($0, 0) == 0 }
        check("tree: every pid reaped by tree-kill", aliveAfter.isEmpty, "alive=\(aliveAfter)")
        proc.release()
    } else {
        check("tree: spawn succeeded", false, "spawn failed")
    }

    // A leader that dies FIRST must not leave its children behind: they're reparented to launchd and
    // would keep the port and RAM. handleExit sweeps the tree, which only works because sessionMembers
    // falls back to the dead leader's pid as the session id.
    let crashy = Project(name: "crashy", path: "/tmp",
                         devCommand: "sh -c 'sleep 57 & echo CHILD=$!; exit 3'", memoryGB: 1)
    let crashSession = DevSession(project: crashy)
    crashSession.start(memoryGB: 1)
    var childPid: pid_t = 0
    for _ in 0..<40 where childPid == 0 {
        try? await Task.sleep(for: .milliseconds(100))
        if let line = crashSession.logLines.first(where: { $0.hasPrefix("CHILD=") }) {
            childPid = pid_t(line.dropFirst("CHILD=".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    check("orphan: crashing leader reported its child", childPid > 0)
    if childPid > 0 {
        try? await Task.sleep(for: .seconds(1.5))
        let swept = kill(childPid, 0) != 0
        check("orphan: child of a crashed leader is swept, not left running", swept,
              swept ? "" : "pid \(childPid) still alive")
        if kill(childPid, 0) == 0 { kill(childPid, SIGKILL) }
    }
    crashSession.stop()

    // Port probe: sees IPv4 and IPv6-only listeners, and a closed port reads free.
    func listener(ipv6: Bool) -> (fd: Int32, port: Int) {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        if ipv6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size)) }
        var bound: Int32 = -1
        if ipv6 {
            var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6); a.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET); a.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return (-1, 0) }
        var ss = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len) } }
        let port = withUnsafePointer(to: &ss) { p -> Int in
            ipv6 ? p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
                 : p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
        }
        return (fd, port)
    }
    let v4 = listener(ipv6: false)
    check("port: IPv4 listener detected", v4.fd >= 0 && DevSession.isPortInUse(v4.port), "port \(v4.port)")
    check("port: firstFreePort skips a taken port",
          DevSession.firstFreePort(from: v4.port, avoiding: []) != v4.port)
    close(v4.fd)
    check("port: a closed port reads free", !DevSession.isPortInUse(v4.port), "port \(v4.port)")
    check("port: firstFreePort returns the start when it's free",
          DevSession.firstFreePort(from: v4.port, avoiding: []) == v4.port)
    check("port: firstFreePort skips a port reserved by a sibling session",
          DevSession.firstFreePort(from: v4.port, avoiding: [v4.port]) != v4.port)
    let v6 = listener(ipv6: true)
    check("port: IPv6-only listener detected (Vite/Astro bind ::1)", v6.fd >= 0 && DevSession.isPortInUse(v6.port),
          "port \(v6.port)")
    close(v6.fd)

    return failures
}

let failures = await runSessionTests()
print(failures == 0 ? "ALL SESSION TESTS PASSED" : "\(failures) SESSION TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
