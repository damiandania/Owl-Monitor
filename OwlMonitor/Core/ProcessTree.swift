import Foundation

/// Enumerates the process tree of a supervised dev server.
enum ProcessTree {
    /// All pids in the same session as `leader`. We spawn with `setsid` + `exec`, so the
    /// leader is a session leader and the whole tree shares its session id — robust to the
    /// re-parenting / process-group churn that shells like p10k/fnm introduce.
    ///
    /// Works after the leader has DIED, too. getsid() fails for a dead pid, and this used to give up
    /// and return just `[leader]` — so a tree-kill aimed at a crashed server found nothing, and its
    /// children (which SIGKILL on the leader never reaches) lived on as orphans holding the port and
    /// RAM. Our leaders are spawned with setsid, so their session id IS their pid, and every member
    /// keeps that sid even once reparented to launchd: fall back to it and the survivors are found.
    static func sessionMembers(of leader: pid_t) -> [pid_t] {
        guard leader > 0 else { return [] }
        let sid = getsid(leader)
        let session = sid > 0 ? sid : leader
        var buffer = [pid_t](repeating: 0, count: 1024)
        let count = Int(dm_session_pids(session, &buffer, 1024))
        return count > 0 ? Array(buffer[0..<count]) : [leader]
    }

    /// Every pid reachable from `leader`: the session members PLUS any descendant reachable by the
    /// parent→child (ppid) link. The ppid walk is what catches a child that called `setsid()` — that
    /// gives the child a NEW session and process group, so both `killpg` and `sessionMembers` miss
    /// it, but its parent pid is unchanged, so `proc_listchildpids` (via `dm_child_pids`) still finds
    /// it. Used by the tree-kill so a detached worker can't outlive the server that started it.
    static func fullTree(of leader: pid_t) -> [pid_t] {
        guard leader > 0 else { return [] }
        var seen = Set<pid_t>(sessionMembers(of: leader))
        seen.insert(leader)
        var frontier = Array(seen)
        var buf = [pid_t](repeating: 0, count: 256)
        while let p = frontier.popLast() {
            let n = Int(dm_child_pids(p, &buf, 256))
            for i in 0..<n where buf[i] > 1 && !seen.contains(buf[i]) {
                seen.insert(buf[i])
                frontier.append(buf[i])
            }
        }
        return Array(seen)
    }
}
