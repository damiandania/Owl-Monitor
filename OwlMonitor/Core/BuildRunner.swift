import Foundation
import Observation
import Darwin

/// Runs the project's build script as a tracked one-shot process, separate from the
/// dev server. Streams its log and reports success/failure.
@MainActor
@Observable
final class BuildRunner {
    let project: Project
    private(set) var isRunning = false
    private(set) var logLines: [String] = []
    private(set) var result: Int32?   // nil while running; 0 = success, else failure

    private(set) var pid: pid_t = 0
    /// When the build process started — drives the elapsed-time counter in the terminal pane.
    private(set) var startedAt: Date?
    /// Wall-clock duration of the finished build (nil while running) — used as the ETA for the next.
    private(set) var duration: TimeInterval?
    private var process: SpawnedProcess?
    private var consumeTask: Task<Void, Never>?
    private var lineBuffer = LineBuffer()
    private let maxLogLines = 4000
    /// Full build output mirrored to disk (ANSI-stripped), fresh per build. `logLines` is capped and
    /// the CLI only surfaces a tail, so this file is the one place the WHOLE error survives.
    private var logFile: FileHandle?
    /// Set when `stop()` is called so the signal-killed exit isn't reported as a build *failure*
    /// (the dashboard shows "Stopped", not "Failed").
    private(set) var wasStopped = false

    var onEvent: (@MainActor (SupervisionEvent) -> Void)?
    /// Fired once when the build process exits. `success` is true on exit code 0.
    /// Used by the orchestrator to relaunch a server that was stopped for the build.
    var onFinish: (@MainActor (Bool) -> Void)?

    init(project: Project) { self.project = project }

    var buildCommand: String {
        project.buildCommand ?? "\(project.packageManager.runScriptPrefix) build"
    }

    func start(memoryGB: Int) {
        guard !isRunning else { return }
        // Resolve the user's login+interactive PATH into our env BEFORE spawning, so the build finds
        // node/npm. Without it, a build run right after a GUI launch — before any dev server resolved
        // the PATH in this process — inherits the bare launchd PATH and dies with `node: not found`
        // (exit 127). DevSession/WorkerRunner do the same; a build must too, since it can be the very
        // first thing spawned. See ShellEnvironment.
        if ShellEnvironment.applyResolvedPATH() == nil {
            AppLog.shared.event("BuildRunner: could not resolve the user shell PATH for \(project.name) — using inherited PATH")
        }
        // Inject the same heap as the dev server (--max-old-space-size) so a large build doesn't OOM
        // where a bare `npm run build` would. NOTE: only NODE_OPTIONS-allowlisted flags work here —
        // V8 flags like --optimize-for-size are REJECTED ("not allowed in NODE_OPTIONS") and make
        // node exit immediately (code 9), failing every build. Keep it to --max-old-space-size.
        let nodeOpts = ProcessSupport.nodeHeapFlag(memoryGB: memoryGB)
        let userEnv = ProcessSupport.envAssignments(project.env)
        let launch = "NODE_OPTIONS='\(nodeOpts)' FORCE_COLOR=0 exec \(buildCommand)"
        let command = "\(userEnv)\(launch)"
        let header = ProcessSupport.displayCommand(env: project.env, rest: launch, cwd: project.path)
        logLines = [header]
        lineBuffer.reset()
        openLogFile(header: header)
        result = nil
        duration = nil
        startedAt = Date()
        wasStopped = false
        isRunning = true

        guard let proc = SpawnedProcess.spawn(command: command, cwd: project.path, wantsStdin: false) else {
            isRunning = false
            result = -1
            logLines.append("build: failed to spawn")
            return
        }
        pid = proc.pid
        process = proc

        let stream = proc.chunks   // captured by the consume task; does NOT retain `proc`
        consumeTask = Task { @MainActor [weak self] in
            for await chunk in stream {
                guard let self else { continue }
                switch chunk {
                case .data(let data): self.ingest(data)
                case .eof: self.process?.cancelReader()
                case .exit(let code): self.finish(code: code)
                }
            }
        }
    }

    func stop() {
        guard pid > 0 else { return }
        wasStopped = true
        ProcessSupport.gracefulKillTree(pid)
    }

    private func ingest(_ data: Data) {
        // One observable mutation per chunk (not per line) — `logLines` is observed, so per-line
        // appends re-render every observing view once per line. Trim with slack, in chunks:
        // a per-line removeFirst is O(count) each time once the cap is reached.
        let fresh = lineBuffer.ingest(data).filter { !LogNoise.isShellNoise($0) }
        guard !fresh.isEmpty else { return }
        logLines.append(contentsOf: fresh)
        if logLines.count > maxLogLines + 200 {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        // Mirror the FULL output to disk (unlike the capped in-memory buffer) so the whole error is
        // recoverable — that's the point of the file.
        if let data = fresh.map({ $0.strippedANSI + "\n" }).joined().data(using: .utf8) {
            logFile?.write(data)
        }
    }

    private func finish(code: Int32) {
        process?.release()
        pid = 0
        isRunning = false
        result = code
        if let s = startedAt { duration = Date().timeIntervalSince(s) }
        // A user-initiated stop() kills the process with a signal (non-zero exit); don't post a
        // "Build failed" banner for a build the user deliberately cancelled. The feed/onFinish still
        // fire so the orchestrator can relaunch the paused dev server.
        if wasStopped {
            logLines.append("build stopped")
        } else {
            logLines.append("build finished (code \(code))")
            onEvent?(.buildFinished(project: project.name, success: code == 0))
        }
        let tail = (wasStopped ? "build stopped" : "build finished (code \(code))") + "\n"
        logFile?.write(Data(tail.utf8))
        try? logFile?.close()
        logFile = nil
        onFinish?(code == 0)
    }

    /// Open the build log fresh (truncated) for this run — one build's output at a time, so the file
    /// is never a confusing mix of past builds. Mirrors `DevSession.openLogFile`'s directory handling.
    private func openLogFile(header: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Project.logsDirectory, withIntermediateDirectories: true)
        let url = project.buildLogFileURL
        fm.createFile(atPath: url.path, contents: Data())   // truncate: a build log is per-run
        logFile = try? FileHandle(forWritingTo: url)
        if logFile == nil {
            AppLog.shared.event("BuildRunner: could not open build log for \(project.name) at \(url.path)")
            return
        }
        logFile?.write(Data((header + "\n").utf8))
    }
}
