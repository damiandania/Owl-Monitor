import Foundation
import Darwin
import os

/// Finds and removes "zombie servers": trees Owl Monitor started but no longer supervises.
///
/// Both ways they arise were reproduced on a real machine:
/// - **Owl Monitor itself dies** (a crash, Force Quit). Every tree runs in its own session, so it
///   survives, reparented to launchd — still holding its port and RAM — while the relaunched app
///   shows the project as "Idle" and knows nothing about it.
/// - **A tree's leader dies first.** Its children, which the leader's SIGKILL never reached, are
///   reparented to launchd. (`DevSession.handleExit` sweeps these at once now; this is the net.)
///
/// Ownership is certain, never guessed from command lines: every tree carries
/// `OWL_MONITOR_PROJECT=<id>:<kind>` in its environment (see `ProcessSupport.ownershipTag`), so a
/// server you started yourself, an editor or a launchd service is never touched. And only launchd's
/// direct children are examined: the root of every orphaned tree ends up there, while a live tree
/// hangs off Owl Monitor — so a server being launched at this very moment can never be mistaken for
/// an orphan.
enum OrphanReaper {
    /// The root of one orphaned tree: a launchd child wearing our tag for a (project, kind) that has
    /// no live supervised runner.
    struct Orphan: Sendable {
        let pid: pid_t
        let projectID: UUID
        /// "dev", "preview", "worker" or "build" — what the tree was, so it can be recovered as such.
        let kind: String
    }

    /// `<id>:<kind>` for a live runner — the same string the tag carries — so `scan` can skip it.
    static func key(projectID: UUID, kind: String) -> String { "\(projectID.uuidString):\(kind)" }

    /// Tagged launchd children whose `<id>:<kind>` isn't in `supervised`. Pure — it only reads, so a
    /// caller can log or report before killing. Blocking: call it off the main actor.
    nonisolated static func scan(supervised: Set<String>) -> [Orphan] {
        var children = [pid_t](repeating: 0, count: 4096)
        let n = Int(dm_child_pids(1, &children, 4096))
        guard n > 0 else { return [] }
        var found: [Orphan] = []
        let live = Array(children.prefix(n))
        // Session membership for the whole machine, built once per scan and only if some root needs
        // it. Asking per root walked every process again for each one — K roots × N processes.
        var sessions: [pid_t: [pid_t]]?
        func members(of sid: pid_t) -> [pid_t] {
            if sessions == nil { sessions = sessionMap() }
            return sessions?[sid] ?? []
        }
        // Many roots share one big session (the login session holds most GUI apps), so the same
        // session would be searched once per root; answer each session once per scan.
        var sessionTags: [pid_t: String?] = [:]
        func sessionTag(_ sid: pid_t, excluding root: pid_t) -> String? {
            if let known = sessionTags[sid] { return known }
            let tag = members(of: sid).lazy.filter { $0 != root && $0 > 1 }.compactMap { ownTag(of: $0) }.first
            sessionTags[sid] = tag
            return tag
        }
        for pid in live where pid > 1 {
            guard let tag = cachedTreeTag(ofRoot: pid, sessionTag: sessionTag), !supervised.contains(tag) else { continue }
            let parts = tag.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { continue }
            found.append(Orphan(pid: pid, projectID: id, kind: String(parts[1])))
        }
        // Forget processes that are gone, so the cache tracks launchd's children and nothing else.
        let alive = Set(live)
        verdicts.withLock { $0 = $0.filter { alive.contains($0.key) } }
        let present = Set((sessions ?? [:]).values.flatMap { $0 })
        if !present.isEmpty { envTags.withLock { $0 = $0.filter { present.contains($0.key) } } }
        return found
    }

    /// What `treeTag` said about each launchd child, keyed by pid and checked against its start time.
    /// launchd's children are mostly long-lived apps and daemons; re-reading every one's environment
    /// each sweep (and, for Apple binaries, walking all processes for its session) cost ~0.3 s of CPU
    /// per 30 s scan. A process's environment and session never change, so one look is enough.
    private static let verdicts = OSAllocatedUnfairLock<[pid_t: (start: UInt64, tag: String?)]>(initialState: [:])

    /// A process's OWN tag (its environment never changes), read once per process lifetime.
    private static let envTags = OSAllocatedUnfairLock<[pid_t: (start: UInt64, tag: String?)]>(initialState: [:])

    private static func ownTag(of pid: pid_t) -> String? {
        let start = dm_proc_start_time(pid)
        if start != 0, let hit = envTags.withLock({ $0[pid] }), hit.start == start { return hit.tag }
        var value = [CChar](repeating: 0, count: 128)
        let tag = dm_proc_env_value(pid, ProcessSupport.ownershipKey, &value, Int32(value.count)) > 0
            ? String(cString: value) : nil
        if start != 0 { envTags.withLock { $0[pid] = (start, tag) } }
        return tag
    }

    private static func cachedTreeTag(ofRoot pid: pid_t, sessionTag: (pid_t, pid_t) -> String?) -> String? {
        let start = dm_proc_start_time(pid)
        if start != 0, let hit = verdicts.withLock({ $0[pid] }), hit.start == start { return hit.tag }
        let (tag, final) = treeTag(ofRoot: pid, sessionTag: sessionTag)
        // Only verdicts that can't change are kept: ones read from the root's OWN environment. One that
        // came from walking its session can — a tagged process may join that session later.
        if start != 0, final { verdicts.withLock { $0[pid] = (start, tag) } }
        return tag
    }

    /// Every process grouped by session id, from one pass over the process table.
    private static func sessionMap() -> [pid_t: [pid_t]] {
        var all = [pid_t](repeating: 0, count: 8192)
        let n = Int(dm_all_pids(&all, Int32(all.count)))
        var map: [pid_t: [pid_t]] = [:]
        for pid in all.prefix(max(n, 0)) where pid > 1 {
            let sid = getsid(pid)
            if sid > 0 { map[sid, default: []].append(pid) }
        }
        return map
    }

    /// The ownership tag of the tree rooted at launchd child `pid`, or nil when it isn't ours.
    ///
    /// Usually read straight off `pid`. But macOS hides the environment of Apple's own binaries
    /// (`sh`, `make`, …), and one of those can be the root of an orphaned tree — npm's `sh -c` child
    /// once npm itself died, or a `make dev` leader after Owl Monitor crashed. Those, and any survivor
    /// whose session leader is gone, are identified by their SESSION instead: every tree we spawn gets
    /// a session of its own (setsid), and membership is only ever inherited, so a tagged member
    /// anywhere in it proves the root is ours. A session leader with a readable, untagged
    /// environment — every app you launched yourself — is ruled out without looking further, and
    /// other users' processes refuse the read outright: the scan stays cheap.
    /// `final` is false when the answer came from the session rather than the root itself.
    private static func treeTag(ofRoot pid: pid_t, sessionTag: (pid_t, pid_t) -> String?) -> (tag: String?, final: Bool) {
        var value = [CChar](repeating: 0, count: 128)
        let direct = dm_proc_env_value(pid, ProcessSupport.ownershipKey, &value, Int32(value.count))
        if direct > 0 { return (String(cString: value), true) }
        let sid = getsid(pid)
        guard sid > 0 else { return (nil, false) }
        guard direct == -2 || sid != pid else { return (nil, true) }   // a readable, untagged leader
        return (sessionTag(sid, pid), false)
    }

    /// Kill each orphan's whole tree: SIGTERM now, SIGKILL for anything still standing after a grace.
    nonisolated static func reap(_ orphans: [Orphan]) {
        for orphan in orphans { ProcessSupport.gracefulKillTree(orphan.pid) }
    }
}
