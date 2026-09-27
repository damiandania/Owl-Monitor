import Foundation

enum GitInfo {
    /// One entry of `git worktree list` — a checkout directory pinned to a branch (or detached).
    struct Worktree: Identifiable, Hashable, Sendable {
        var path: String
        var branch: String?      // short branch name; nil when detached
        var isCurrent: Bool
        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// Size of the uncommitted changes — line counts from `git diff HEAD`.
    struct DiffStat: Equatable, Sendable {
        var added: Int
        var removed: Int
        var isEmpty: Bool { added == 0 && removed == 0 }
    }

    /// Current branch for a project path. Handles both a normal clone (`.git` is a directory) and a
    /// linked worktree (`.git` is a file pointing at the real gitdir). nil if not a git repo.
    static func branch(for projectPath: String) -> String? {
        guard let head = headPath(for: projectPath),
              let content = try? String(contentsOfFile: head, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if trimmed.hasPrefix(prefix) { return String(trimmed.dropFirst(prefix.count)) }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))  // detached HEAD
    }

    /// Uncommitted line changes vs HEAD (staged + unstaged tracked edits), summed from
    /// `git diff HEAD --numstat`. nil when not a git repo or the repo has no commits yet; a clean tree
    /// yields (0, 0). Untracked files aren't counted — they're not part of the diff. Blocking — call
    /// off the main thread.
    static func diffStat(for projectPath: String) -> DiffStat? {
        guard let out = run(["diff", "HEAD", "--numstat"], cwd: projectPath) else { return nil }
        var added = 0, removed = 0
        for raw in out.split(separator: "\n") {
            let cols = raw.split(separator: "\t")
            guard cols.count >= 2 else { continue }
            added   += Int(cols[0]) ?? 0     // "-" for binary files → counts as 0
            removed += Int(cols[1]) ?? 0
        }
        return DiffStat(added: added, removed: removed)
    }

    /// Resolve the path to the `HEAD` file, following the worktree `.git`-file pointer when present.
    /// A linked worktree's `.git` is a regular file `gitdir: <abs path to .git/worktrees/<name>>`.
    private static func headPath(for projectPath: String) -> String? {
        let gitPath = projectPath + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return gitPath + "/HEAD" }
        guard let pointer = try? String(contentsOfFile: gitPath, encoding: .utf8) else { return nil }
        let line = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return nil }
        let dir = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        return dir + "/HEAD"
    }

    /// All worktrees of the repo `projectPath` belongs to, via `git worktree list --porcelain`.
    /// Empty if not a git repo or git is unavailable. Blocking — call off the main thread.
    static func worktrees(for projectPath: String) -> [Worktree] {
        guard let out = run(["worktree", "list", "--porcelain"], cwd: projectPath) else { return [] }
        var result: [Worktree] = []
        var path: String?
        var branch: String?
        var detached = false
        func flush() {
            guard let p = path else { return }
            result.append(Worktree(path: p, branch: detached ? nil : branch, isCurrent: sameDir(p, projectPath)))
            path = nil; branch = nil; detached = false
        }
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst("worktree ".count)) }
            else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))   // e.g. refs/heads/main
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
            else if line == "detached" { detached = true }
            else if line.isEmpty { flush() }
        }
        flush()
        return result
    }

    /// Create a new worktree. `branch` is checked out, or created from HEAD with `-b` when
    /// `createBranch`. Returns nil on success, or git's stderr message on failure. Blocking — call
    /// off the main thread.
    @discardableResult
    static func addWorktree(repoPath: String, at newPath: String, branch: String, createBranch: Bool) -> String? {
        let args = ["worktree", "add"] + (createBranch ? ["-b", branch, newPath] : [newPath, branch])
        let r = runResult(args, cwd: repoPath)
        if r.status == 0 { return nil }
        return r.stderr.isEmpty ? "git exited with status \(r.status)" : r.stderr
    }

    /// Local branch names (most-recently-committed first) as `git switch` targets. Blocking — call
    /// off the main thread.
    static func localBranches(for projectPath: String) -> [String] {
        guard let out = run(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"],
                            cwd: projectPath) else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Switch the working tree to `branch` (`git switch`). Returns nil on success, or git's stderr
    /// message on failure (e.g. uncommitted changes, or the branch is already checked out in another
    /// worktree). Blocking — call off the main thread.
    @discardableResult
    static func switchBranch(repoPath: String, to branch: String) -> String? {
        let r = runResult(["switch", branch], cwd: repoPath)
        if r.status == 0 { return nil }
        return r.stderr.isEmpty ? "git exited with status \(r.status)" : r.stderr
    }

    // MARK: - Process plumbing

    private static func sameDir(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// The git to drive, resolved ONCE to the first candidate that actually runs. `/usr/bin/git` is
    /// the Xcode command-line shim, and it refuses to run AT ALL — exit 69, "You have not agreed to
    /// the Xcode license agreements" — after every Xcode update until the licence is accepted. Hard-
    /// coding it meant every git call here failed while a perfectly good Homebrew git sat next to it
    /// (and the user's own terminal, whose PATH finds that one first, looked fine — so the app seemed
    /// to be the broken part). The shim stays LAST so that when it's the only git installed its own
    /// message is still what surfaces.
    private static let gitPath: String = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first(where: runs) ?? "/usr/bin/git"
    }()

    /// Whether `path` is an executable that answers `git --version` with status 0 — presence on disk
    /// isn't enough, since the shim exists and is executable even while it refuses to do anything.
    private static func runs(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private static func run(_ args: [String], cwd: String) -> String? {
        let r = runResult(args, cwd: cwd)
        return r.status == 0 ? r.stdout : nil
    }

    /// Run `git -C <cwd> <args>` and capture status/stdout/stderr. Outputs here are tiny (worktree
    /// listing/creation), so reading each pipe to EOF before `waitUntilExit` is safe.
    private static func runResult(_ args: [String], cwd: String) -> (status: Int32, stdout: String, stderr: String) {
        let git = gitPath
        guard FileManager.default.isExecutableFile(atPath: git) else { return (127, "", "git not found at \(git)") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: git)
        proc.arguments = ["-C", cwd] + args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        do { try proc.run() } catch { return (127, "", "\(error)") }
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus,
                String(data: oData, encoding: .utf8) ?? "",
                String(data: eData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
