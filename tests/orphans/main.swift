import Foundation
import Darwin

// Tests the zombie-server defences end to end, on real processes:
//   1. dm_proc_env_value reads the ownership tag out of ANOTHER process's environment — including
//      one that rewrote its own title (Node's process.title zero-fills the argv block, which used
//      to hide the environment and with it the tag).
//   2. ProcessTree finds a tree's survivors after its leader has died.
//   3. OrphanReaper reports only tagged launchd children with no live runner, and reaps them.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}
func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

// Sleeper mode: a stand-in for a server process. Unlike /bin/sleep it's not an Apple platform
// binary, so — like node — its environment (and the tag in it) is readable.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--sleep-child" {
    sleep(UInt32(CommandLine.arguments[2]) ?? 30)
    exit(0)
}

// Child mode (re-exec'd below): do what Node's process.title does — overwrite argv[0] in place and
// zero-fill the rest of the argv block — then wait to be inspected.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--title-child" {
    let argv = CommandLine.unsafeArgv
    let first = argv[0]!, last = argv[Int(CommandLine.argc) - 1]!
    memset(first, 0, last + strlen(last) - first)
    strcpy(first, "owl-title")
    print("ready"); fflush(stdout)
    sleep(30)
    exit(0)
}

let key = ProcessSupport.ownershipKey
var buf = [CChar](repeating: 0, count: 128)

// ── 1. Reading the tag ─────────────────────────────────────────────────────
let titleID = UUID()
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
// Long arguments so the zero-filled run is far longer than argc strings — the case that broke.
child.arguments = ["--title-child", String(repeating: "x", count: 300), String(repeating: "y", count: 300)]
child.environment = ProcessInfo.processInfo.environment.merging([key: "\(titleID.uuidString):dev"]) { $1 }
let childOut = Pipe()
child.standardOutput = childOut
do { try child.run() } catch { print("FAIL could not start title child: \(error)"); exit(1) }
_ = childOut.fileHandleForReading.availableData   // blocks until "ready": argv is rewritten
let cpid = child.processIdentifier

let n = dm_proc_env_value(cpid, key, &buf, Int32(buf.count))
chk(n > 0 && String(cString: buf) == "\(titleID.uuidString):dev",
    "env: tag read despite a rewritten, zero-filled argv block", n > 0 ? String(cString: buf) : "n=\(n)")
chk(dm_proc_env_value(cpid, "OWL_NO_SUCH_VAR", &buf, Int32(buf.count)) == -1, "env: absent key → -1")
chk(dm_proc_env_value(cpid, "OWL_MONITOR", &buf, Int32(buf.count)) == -1, "env: a key PREFIX doesn't match")
var small = [CChar](repeating: 0, count: 9)
chk(dm_proc_env_value(cpid, key, &small, Int32(small.count)) == 8 && String(cString: small).count == 8,
    "env: value truncated to the buffer, NUL-terminated")
chk(dm_proc_env_value(1, "PATH", &buf, Int32(buf.count)) == -1, "env: another user's process is unreadable → -1")

// A tagged process that hangs off a LIVE parent (us) is a tree being supervised — never an orphan.
chk(!OrphanReaper.scan(supervised: []).contains { $0.pid == cpid }, "reaper: a tagged child of a live parent is ignored")
child.terminate(); child.waitUntilExit()

// ── 2. Survivors of a dead leader ──────────────────────────────────────────
var outFD: Int32 = -1
let leader = dm_spawn_session("sleep 31 & sleep 31 & exit 0", "/tmp", &outFD, nil)
chk(leader > 0, "tree: spawned a session leader")
if leader > 0 {
    var status: Int32 = 0
    waitpid(leader, &status, 0)   // the leader is gone; its two sleeps live on
    let survivors = ProcessTree.sessionMembers(of: leader).filter { $0 != leader }
    chk(survivors.count == 2, "tree: dead leader's session members still found", "\(survivors)")
    ProcessSupport.gracefulKillTree(leader)
    usleep(500_000)
    chk(!survivors.contains(where: alive), "tree: tree-kill aimed at the dead leader reaps its survivors")
    survivors.filter(alive).forEach { kill($0, SIGKILL) }
    if outFD >= 0 { close(outFD) }
}

// ── 3. OrphanReaper over launchd's children ────────────────────────────────
// Each orphan is built the way production leaves one behind: its own session (dm_spawn_session, like
// every launch) whose leader then exits, so the survivors are reparented to launchd.
let me = "'" + URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path + "'"
func orphanSession(_ command: String) {
    var fd: Int32 = -1
    let leader = dm_spawn_session("\(command) </dev/null >/dev/null 2>&1 & exit 0", "/tmp", &fd, nil)
    if leader > 0 { var st: Int32 = 0; waitpid(leader, &st, 0) }
    if fd >= 0 { close(fd) }
}
func pids(where match: (pid_t) -> Bool) -> [pid_t] {
    var kids = [pid_t](repeating: 0, count: 4096)
    let n = Int(dm_child_pids(1, &kids, 4096))
    return kids.prefix(max(n, 0)).filter(match)
}
func args(_ pid: pid_t) -> String {
    var b = [CChar](repeating: 0, count: 1024)
    return dm_proc_args(pid, &b, 1024) > 0 ? String(cString: b) : ""
}

// macOS hides an Apple binary's environment: reported as -2, not as a plain "absent" -1.
orphanSession("/bin/sleep 41")
usleep(300_000)
let plainSleep = pids { args($0).contains("sleep 41") }.first ?? -1
chk(plainSleep > 0 && dm_proc_env_value(plainSleep, key, &buf, Int32(buf.count)) == -2,
    "env: a platform binary's hidden environment → -2")

let directID = UUID(), shellID = UUID()
// (a) The root itself carries the tag — Owl Monitor crashed under a running node leader.
orphanSession("\(key)=\(directID.uuidString):preview exec \(me) --sleep-child 42")
// (b) The root is an Apple binary whose environment macOS hides — npm's `sh -c` child outliving
//     npm — with the tagged process one level down.
orphanSession("/bin/sh -c '\(key)=\(shellID.uuidString):dev \(me) --sleep-child 43; :'")
usleep(400_000)

let scan = OrphanReaper.scan(supervised: [])
// Only ever act on THIS test's orphans — never a real one on the machine running the suite.
let direct = scan.filter { $0.projectID == directID }
let viaShell = scan.filter { $0.projectID == shellID }
chk(direct.count == 1 && direct.first?.kind == "preview" && args(direct[0].pid).contains("--sleep-child 42"),
    "reaper: tagged launchd orphan found with its project and kind", "\(direct.map(\.pid))")
chk(viaShell.count == 1 && viaShell.first?.kind == "dev" && args(viaShell[0].pid).hasPrefix("/bin/sh"),
    "reaper: an Apple-binary root is identified through its session", "\(viaShell.map { args($0.pid) })")
chk(!scan.contains { $0.pid == plainSleep }, "reaper: an untagged orphan is never reported")
chk(OrphanReaper.scan(supervised: [OrphanReaper.key(projectID: directID, kind: "preview")])
        .allSatisfy { $0.projectID != directID },
    "reaper: a (project, kind) with a live runner is skipped")

let sleeperOfShell = viaShell.flatMap { ProcessTree.fullTree(of: $0.pid) }   // sh + its tagged child
OrphanReaper.reap(direct + viaShell)
usleep(600_000)
chk(!(direct + viaShell).map(\.pid).contains(where: alive), "reaper: reap kills each orphan root")
chk(sleeperOfShell.count >= 2 && !sleeperOfShell.contains(where: alive),
    "reaper: …and the whole tree under it", "\(sleeperOfShell)")
chk(plainSleep > 0 && alive(plainSleep), "reaper: reap leaves untagged processes alone")
if plainSleep > 0 { kill(plainSleep, SIGKILL) }
for o in direct + viaShell where alive(o.pid) { kill(o.pid, SIGKILL) }

print(fail == 0 ? "ALL ORPHANS TESTS PASSED" : "\(fail) ORPHANS TEST(S) FAILED")
exit(Int32(fail))
