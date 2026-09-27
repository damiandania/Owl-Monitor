import Foundation
import Darwin

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
        for pid in children.prefix(n) where pid > 1 {
            guard let tag = treeTag(ofRoot: pid), !supervised.contains(tag) else { continue }
            let parts = tag.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { continue }
            found.append(Orphan(pid: pid, projectID: id, kind: String(parts[1])))
        }
        return found
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
    private static func treeTag(ofRoot pid: pid_t) -> String? {
        var value = [CChar](repeating: 0, count: 128)
        let direct = dm_proc_env_value(pid, ProcessSupport.ownershipKey, &value, Int32(value.count))
        if direct > 0 { return String(cString: value) }
        let sid = getsid(pid)
        guard sid > 0, direct == -2 || sid != pid else { return nil }
        for member in ProcessTree.sessionMembers(of: sid) where member != pid && member > 1 {
            if dm_proc_env_value(member, ProcessSupport.ownershipKey, &value, Int32(value.count)) > 0 {
                return String(cString: value)
            }
        }
        return nil
    }

    /// Kill each orphan's whole tree: SIGTERM now, SIGKILL for anything still standing after a grace.
    nonisolated static func reap(_ orphans: [Orphan]) {
        for orphan in orphans { ProcessSupport.gracefulKillTree(orphan.pid) }
    }
}
