import Foundation

setenv("SHELL_SESSIONS_DISABLE", "1", 1)
var fail = 0
func chk(_ l: String, _ c: Bool, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

// 1) per-process rusage for self
let me = getpid()
let s = dm_proc_stat_for(me)
chk("proc rusage valid", s.valid == 1 && s.cpu_time_ns > 0 && s.phys_footprint > 0,
    "cpu_ns=\(s.cpu_time_ns) mem=\(s.phys_footprint / 1_048_576)MB")

// 2) system cpu ticks → sane % across a busy interval
var t0 = dm_cpu_ticks(); _ = dm_system_cpu_ticks(&t0)
var acc = 0.0; for i in 0..<8_000_000 { acc += Double(i).squareRoot() }
var t1 = dm_cpu_ticks(); _ = dm_system_cpu_ticks(&t1)
let dTotal = Double(t1.total &- t0.total), dIdle = Double(t1.idle &- t0.idle)
let cpu = dTotal > 0 ? (1 - dIdle / dTotal) * 100 : -1
chk("system cpu% in 0...100", cpu >= 0 && cpu <= 100, String(format: "%.1f%% (acc=%.0f)", cpu, acc))

// 3) system memory
var m = dm_mem_info(); _ = dm_system_mem(&m)
chk("system mem sane", m.used > 0 && m.used < m.total && m.total > 1_000_000_000,
    "used=\(m.used / 1_048_576)MB / total=\(m.total / 1_048_576)MB")

// 3b) swap usage (total can be 0 if swap is disabled; used must never exceed total)
var sw = dm_mem_info(); let swrc = dm_system_swap(&sw)
chk("swap read ok", swrc == 0 && sw.used <= sw.total,
    "used=\(sw.used / 1_048_576)MB / total=\(sw.total / 1_048_576)MB")

// 4) load average
let la = dm_load_avg()
chk("load avg > 0", la > 0, "\(la)")

// 5) child enumeration on a spawned tree
var fd: Int32 = -1
// Force a real fork tree (two background children under the zsh leader).
let pid = dm_spawn_session("sleep 3 & sleep 3 & wait", "/tmp", &fd, nil)
usleep(500_000)
var kids = [pid_t](repeating: 0, count: 64)
let n = Int(dm_child_pids(pid, &kids, 64))
print("INFO leader=\(pid) children=\(n): \(Array(kids[0..<max(0, min(n, 8))]))")
chk("child enumeration finds children", n >= 1, "n=\(n)")
killpg(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0); close(fd)

// 6) CPU temperature — called twice to exercise the cached sensor-service list. Apple Silicon
// reads a plausible °C; Intel/VMs may have no readable sensor (-1 both times); never crashes.
let temp1 = dm_cpu_temperature()
let temp2 = dm_cpu_temperature()
chk("cpu temperature plausible (cached services)",
    (temp1 == -1 && temp2 == -1) || (temp1 > 0 && temp1 < 150 && temp2 > 0 && temp2 < 150),
    "t1=\(temp1) t2=\(temp2)")

// 7) process name / argv for self
var nameBuf = [CChar](repeating: 0, count: 256)
let selfName = Int(dm_proc_name(getpid(), &nameBuf, 256)) > 0 ? String(cString: nameBuf) : ""
chk("proc name for self", selfName.contains("metrics"), "name=\(selfName)")
var argsBuf = [CChar](repeating: 0, count: 4096)
let selfArgs = Int(dm_proc_args(getpid(), &argsBuf, 4096)) > 0 ? String(cString: argsBuf) : ""
chk("proc args for self", selfArgs.contains("metrics"), "args=\(selfArgs.prefix(80))")

// 8) session enumeration contains self
var sess = [pid_t](repeating: 0, count: 1024)
let sn = Int(dm_session_pids(getsid(getpid()), &sess, 1024))
chk("session pids include self", (0..<sn).contains { sess[$0] == getpid() }, "n=\(sn)")

// 9) listen-port detection against a real ephemeral listener in this process
let sock = socket(AF_INET, SOCK_STREAM, 0)
var sin = sockaddr_in()
sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
sin.sin_family = sa_family_t(AF_INET)
sin.sin_port = 0                                  // ephemeral — the kernel picks a free port
sin.sin_addr.s_addr = inet_addr("127.0.0.1")
var bindOK = false
withUnsafePointer(to: &sin) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bindOK = bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
    }
}
_ = listen(sock, 1)
var bound = sockaddr_in()
var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
withUnsafeMutablePointer(to: &bound) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &blen) }
}
let boundPort = Int(UInt16(bigEndian: bound.sin_port))
chk("listener bound", bindOK && boundPort > 0, "port=\(boundPort)")
chk("listen port detected", Int(dm_proc_listen_port(getpid())) == boundPort,
    "detected=\(dm_proc_listen_port(getpid())) expected=\(boundPort)")

// 10) inbound-connection count (idle auto-stop): connections the tree ACCEPTED from outside. A real
// client in another process (nc) holds one open against this process's listener.
let me10 = [getpid()]
func inbound(_ tree: [pid_t], excluding peer: pid_t = 0) -> Int {
    Int(tree.withUnsafeBufferPointer { dm_tree_inbound_count($0.baseAddress, Int32($0.count), peer) })
}
chk("inbound: a bare listener has no connections", inbound(me10) == 0, "count=\(inbound(me10))")
let nc = Process()
nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
nc.arguments = ["127.0.0.1", String(boundPort)]
let ncIn = Pipe(); nc.standardInput = ncIn          // held open: nc keeps the connection up
nc.standardOutput = FileHandle.nullDevice
try? nc.run()
let accepted = accept(sock, nil, nil)
chk("inbound: external client connected", accepted >= 0)
chk("inbound: a connection from another process counts", inbound(me10) == 1, "count=\(inbound(me10))")
chk("inbound: …but not from the excluded peer (Owl Monitor's own probe)",
    inbound(me10, excluding: nc.processIdentifier) == 0, "count=\(inbound(me10, excluding: nc.processIdentifier))")
chk("inbound: …nor from a process of the same tree (bundler ↔ its worker)",
    inbound(me10 + [nc.processIdentifier]) == 0, "count=\(inbound(me10 + [nc.processIdentifier]))")
// This process's OWN outbound connection — to the listener, from inside the tree — never counts.
let client = socket(AF_INET, SOCK_STREAM, 0)
var peer = sin
peer.sin_port = in_port_t(UInt16(boundPort).bigEndian)
_ = withUnsafePointer(to: &peer) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
let acceptedSelf = accept(sock, nil, nil)
chk("inbound: the tree's own loopback connection doesn't count", inbound(me10) == 1, "count=\(inbound(me10))")
close(acceptedSelf); close(client)
nc.terminate(); nc.waitUntilExit()
close(accepted)
usleep(100_000)
chk("inbound: back to zero once the client leaves", inbound(me10) == 0, "count=\(inbound(me10))")
close(sock)

print(fail == 0 ? "ALL METRICS TESTS PASSED" : "\(fail) METRICS TEST(S) FAILED")
exit(fail == 0 ? 0 : 1)
