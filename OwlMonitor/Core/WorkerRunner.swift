import Foundation
import Observation
import Darwin

/// Supervises a project's long-running background **worker** (a queue/job worker, `tsx watch …`, …)
/// — a sibling to the dev server, but without the HTTP machinery: a worker has no port to probe,
/// so there is no health check, recycle-on-hang, or OOM autoscaler here. It just launches the
/// worker command, streams its merged stdout/stderr (with stdin, like the server), and reports
/// running / stopped / crashed. Kept deliberately lean; mirrors `BuildRunner`/`DevSession` shape.
@MainActor
@Observable
final class WorkerRunner {
    let project: Project
    private(set) var isRunning = false
    private(set) var logLines: [String] = []
    private(set) var pid: pid_t = 0
    private(set) var startedAt: Date?
    /// Exit code of the most recent exit (nil until it has exited at least once).
    private(set) var lastExitCode: Int32?
    /// True when the last exit was an unexpected crash (non-zero, not a user-initiated stop). Drives
    /// the red status in the table / tab / dashboard. Cleared on the next launch.
    private(set) var didCrash = false

    private let maxLogLines = 2000
    private var lineBuffer = LineBuffer()
    private var process: SpawnedProcess?
    private var consumeTask: Task<Void, Never>?
    private var stdinFD: Int32 = -1
    /// Set by `stop()` so the signal-killed exit isn't reported as a crash.
    private var wasStopped = false

    init(project: Project) { self.project = project }

    /// The worker command — only ever launched when the project actually has one.
    var workerCommand: String? { project.workerCommand }

    // MARK: - Launch / stop

    func start(memoryGB: Int) {
        guard !isRunning, let baseCommand = workerCommand else { return }
        wasStopped = false
        didCrash = false
        lastExitCode = nil
        logLines.removeAll()
        lineBuffer.reset()
        startedAt = Date()
        isRunning = true

        // Resolve the user's real PATH (fnm/nvm/Homebrew) before spawning, exactly like the dev
        // server — otherwise a GUI launch inherits the minimal launchd PATH and the worker dies with
        // `command not found` (exit 127). See ShellEnvironment / DevSession.start.
        if ShellEnvironment.applyResolvedPATH() == nil {
            AppLog.shared.event("WorkerRunner: could not resolve the user shell PATH for \(project.name) — using inherited PATH")
        }

        // `exec` so the worker REPLACES the login shell and becomes the session leader we spawned,
        // making its whole tree enumerable (by session) and killable (by killpg) — same as the server.
        let nodeOpts = ProcessSupport.nodeHeapFlag(memoryGB: memoryGB)
        let userEnv = ProcessSupport.envAssignments(project.env)
        let launch = "\(ProcessSupport.ownershipTag(projectID: project.id, kind: "worker"))NODE_OPTIONS=\(nodeOpts) FORCE_COLOR=1 exec \(baseCommand)"
        let command = "\(userEnv)\(launch)"
        append(line: ProcessSupport.displayCommand(env: project.env, rest: launch, cwd: project.path))

        guard let proc = SpawnedProcess.spawn(command: command, cwd: project.path, wantsStdin: true) else {
            isRunning = false
            didCrash = true
            append(line: "worker: failed to spawn")
            AppLog.shared.event("WorkerRunner: spawn failed for \(project.name) — cmd: \(launch)")
            return
        }
        pid = proc.pid
        stdinFD = proc.stdinFD
        process = proc

        let stream = proc.chunks   // captured by the consume task; does NOT retain `proc`
        consumeTask = Task { @MainActor [weak self, weak proc] in
            for await chunk in stream {
                guard let self else { continue }
                switch chunk {
                case .data(let data): self.ingest(data)
                // This stream's own process, never `self.process` — see DevSession.start.
                case .eof: proc?.cancelReader()
                case .exit(let code): self.finish(code: code)
                }
            }
        }
    }

    /// Clear the on-screen log (⌘K). In-memory only — the on-disk log is left intact.
    func clearLog() { logLines.removeAll() }

    /// Send a line of input to the running worker's stdin (some workers accept commands).
    func sendInput(_ text: String) {
        guard stdinFD >= 0 else { return }
        let line = text + "\n"
        _ = line.withCString { ptr in write(stdinFD, ptr, strlen(ptr)) }
        append(line: "> \(text)")
    }

    private func closeStdin() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }

    func stop() {
        wasStopped = true
        closeStdin()
        guard pid > 0 else {
            isRunning = false
            return
        }
        append(line: "stop: SIGTERM → kill tree \(pid)")
        ProcessSupport.gracefulKillTree(pid)
        // finish() fires on exit.
    }

    // MARK: - Output handling

    private func ingest(_ data: Data) {
        // One observable mutation per chunk (not per line) — see BuildRunner.ingest.
        let fresh = lineBuffer.ingest(data).filter { !LogNoise.isShellNoise($0.strippedANSI) }
        guard !fresh.isEmpty else { return }
        logLines.append(contentsOf: fresh)
        trimLog()
    }

    private func append(line: String) {
        logLines.append(line)
        trimLog()
    }

    /// Trim with slack, in chunks — a per-line removeFirst is O(count) each time at the cap.
    private func trimLog() {
        if logLines.count > maxLogLines + 200 {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    private func finish(code: Int32) {
        process?.release()
        // Sweep whatever outlived the leader (a crashed leader's children are reparented to launchd
        // and keep running) — see DevSession.handleExit, which does the same.
        if pid > 0 { ProcessSupport.gracefulKillTree(pid) }
        pid = 0
        isRunning = false
        lastExitCode = code
        closeStdin()
        if wasStopped {
            append(line: "worker stopped")
        } else if code == 0 {
            append(line: "worker exited (code 0)")
        } else {
            didCrash = true
            append(line: "worker crashed (code \(code))")
            AppLog.shared.event("WorkerRunner: \(project.name) worker exited with code \(code)")
        }
    }
}
