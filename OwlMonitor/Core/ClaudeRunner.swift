import Foundation

/// Runs the already-logged-in `claude` CLI to produce a READ-ONLY diagnostic report about Dev
/// Monitor itself — it never edits files. Points claude at the app's own source tree and feeds
/// the internal log on stdin.
enum ClaudeRunner {
    struct Report: Sendable {
        var text: String
        var isError: Bool
        var costUSD: Double?
    }

    /// Owl Monitor's own source tree (where the app is developed).
    static let sourcePath = NSHomeDirectory() + "/dev/OwlMonitor"

    /// The Doctor "Live Scan": Claude reads a TIMELINE transcript of Owl Monitor + the machine
    /// (captured live over a couple of minutes by `LiveScan`) and returns a structured, copyable
    /// report — what each process is and who owns it, the activity, errors/bugs, and improvement
    /// points. Runs in the app's own source tree so it can correlate log errors to the code.
    /// Read-only, like `diagnoseProject`. `language` is a BCP-47 code so the report matches the UI.
    static func liveScan(transcript: String, language: String, model: String? = nil) async -> Report {
        let prompt = """
        You are **Owl Monitor**'s built-in diagnostician. Owl Monitor is a native macOS SwiftUI app
        that supervises local dev servers; its source is the current working directory. Below is a
        TIMELINE captured live over the last couple of minutes: machine meters, the process table,
        the supervised sessions/builds/workers, machine-pressure episodes, and Owl Monitor's own
        internal event log (the `LOG:` lines). Each block is timestamped `[t=Ns]`.

        Produce a clear, well-structured **Markdown** report, written in this language (BCP-47 code):
        `\(language)`. Make it easy to copy and paste. Use exactly these sections, in order:

        1. **Summary** — a one-paragraph health verdict.
        2. **Processes & who they belong to** — for every notable process in the snapshots, say what it
           is and WHO owns it (which app, project, editor, CLI or system service), inferring the owner
           from its `argv`, executable path, and any `node_modules` / `.app` bundle / `/extensions/`
           location. Group by owner. Explicitly flag any process you cannot confidently attribute.
        3. **Activity** — what happened across the window: servers starting/stopping, builds, worker
           activity, recycles, pressure episodes, orphans auto-closed.
        4. **Errors & bugs** — concrete errors or anomalies (from the internal log or the state), each
           with the most likely root cause and the file/function involved — read the source to confirm.
           Only real issues; write "None observed" if it looks clean.
        5. **Improvement points** — specific, actionable improvements to Owl Monitor (code or UX),
           most impactful first.

        Be specific: cite pids, names and timestamps from the transcript. DO NOT modify any files.

        --- live timeline ---
        \(transcript)
        """
        return await run(prompt: prompt, cwd: sourcePath, model: model)
    }

    /// Diagnose why a user's dev **project** failed to run or build. Runs in the project's own
    /// directory (`projectPath`) so claude can read its `package.json`, framework config, `.env.example`,
    /// etc., and is fed the supervisor's failure `context` (state, exit code, `lastError`, log tail).
    /// Read-only, like `diagnose`.
    static func diagnoseProject(name: String, projectPath: String, context: String, model: String? = nil) async -> Report {
        let prompt = """
        You are diagnosing why a local dev **project** named "\(name)" failed to run or build. Its
        source is the current working directory — read its own config (package.json / framework
        config / .env.example / lockfile) as needed. Below is Owl Monitor's supervision context: the
        process state, exit code, the failure cause it recorded, and a tail of the process output.
        Identify the single most likely root cause and give a concrete, actionable fix (the exact
        commands to run or file changes to make). Be concise. DO NOT modify any files.

        --- supervision context ---
        \(context)
        """
        return await run(prompt: prompt, cwd: projectPath, model: model)
    }

    /// Holds the Process so the cancellation handler can terminate it from another thread.
    private final class ProcBox: @unchecked Sendable { let process = Process() }

    /// Runs `claude -p` read-only with `prompt` on stdin, in `cwd`, and parses the JSON result.
    /// Read-only by construction: `--permission-mode plan` + disallowed write tools. An optional
    /// `model` (e.g. "claude-haiku-4-5") selects a faster/cheaper model. **Cancellable**: cancelling
    /// the surrounding Task terminates the claude subprocess (Stop button in the Doctor panel).
    static func run(prompt: String, cwd: String, model: String? = nil) async -> Report {
        let box = ProcBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // The model id is handed to the script as a positional parameter (`"$1"`), never spliced into
        // the script text: it's read back from settings.json on disk, so an interpolated value like
        // `x; curl … | sh` would be executed by the login shell. `zsh` fills `$0`.
        let script = "claude -p --output-format json --permission-mode plan "
            + "--disallowed-tools 'Edit Write MultiEdit NotebookEdit' --no-session-persistence"
            + (model == nil ? "" : " --model \"$1\"")
        process.arguments = ["-lc", script, "zsh"] + (model.map { [$0] } ?? [])
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Discarded, not piped: nothing ever read the old stderr pipe, so a chatty `claude` (>~64 KB
        // of warnings) filled its buffer and blocked forever — hanging the Doctor with no way out.
        process.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Report, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: Report(
                            text: "Could not launch claude: \(error.localizedDescription)",
                            isError: true, costUSD: nil))
                        return
                    }

                    if let data = prompt.data(using: .utf8) {
                        stdin.fileHandleForWriting.write(data)
                    }
                    try? stdin.fileHandleForWriting.close()

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    if let object = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                       let result = object["result"] as? String {
                        continuation.resume(returning: Report(
                            text: result,
                            isError: (object["is_error"] as? Bool) ?? false,
                            costUSD: object["total_cost_usd"] as? Double))
                    } else {
                        let raw = String(data: outData, encoding: .utf8) ?? ""
                        continuation.resume(returning: Report(
                            text: raw.isEmpty ? "claude produced no output." : raw,
                            isError: true, costUSD: nil))
                    }
                }
            }
        } onCancel: {
            box.process.terminate()   // stop the claude subprocess when the Task is cancelled
        }
    }
}
