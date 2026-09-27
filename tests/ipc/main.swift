import Foundation

// Tests the IPC surface end-to-end at the wire level: the Codable protocol contract (incl. the
// structured status fields) and a real framed write→read roundtrip through IPCIO over a pipe.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

// 1) IPCMessage / IPCServerInfo Codable roundtrip — the agent-facing structured fields survive.
let info = IPCServerInfo(name: "dm", path: "/p", state: "Running · :3000", port: 3000,
    logPath: "/l.log", ready: true, url: "http://localhost:3000/", pid: 42, exitCode: nil, lastError: nil)
guard let encMsg = try? JSONEncoder().encode(IPCMessage(type: "status", servers: [info], message: nil)),
      let backMsg = try? JSONDecoder().decode(IPCMessage.self, from: encMsg),
      let bi = backMsg.servers?.first else { print("FAIL ipc: IPCMessage roundtrip"); exit(1) }
chk(backMsg.type == "status" && backMsg.servers?.count == 1, "IPCMessage roundtrip")
chk(bi.ready == true && bi.url == "http://localhost:3000/" && bi.pid == 42 && bi.port == 3000 && bi.logPath == "/l.log",
    "IPCServerInfo structured fields preserved")

// 2) IPCRequest roundtrip.
guard let encReq = try? JSONEncoder().encode(IPCRequest(cmd: "up", path: "/proj", name: nil, gb: 8, all: nil)),
      let backReq = try? JSONDecoder().decode(IPCRequest.self, from: encReq) else { print("FAIL ipc: IPCRequest roundtrip"); exit(1) }
chk(backReq.cmd == "up" && backReq.path == "/proj" && backReq.gb == 8, "IPCRequest roundtrip")

// 3) Real framed I/O through IPCIO over a pipe: write → readLine → decode (the hub's exact framing).
var fds = [Int32](repeating: 0, count: 2)
chk(pipe(&fds) == 0, "pipe created")
let rfd = fds[0], wfd = fds[1]
IPCIO.write(wfd, IPCMessage(type: "ok", servers: nil, message: "launched dm (Nuxt, 8 GB)"))
close(wfd)
let line = IPCIO.readLine(rfd)
close(rfd)
chk(line != nil, "readLine returned a frame")
let decoded = line.flatMap { try? JSONDecoder().decode(IPCMessage.self, from: $0) }
chk(decoded?.type == "ok" && decoded?.message == "launched dm (Nuxt, 8 GB)", "framed write→read roundtrip")

// 3b) A request line over IPCIO.maxRequestBytes is refused (nil), not buffered without bound — and
// the ceiling leaves plenty of room for a real request.
let bigURL = URL(fileURLWithPath: NSTemporaryDirectory() + "dm-ipc-big-\(getpid()).txt")
try? (String(repeating: "a", count: IPCIO.maxRequestBytes + 10) + "\n").write(to: bigURL, atomically: true, encoding: .utf8)
let bigFD = open(bigURL.path, O_RDONLY)
chk(bigFD >= 0 && IPCIO.readLine(bigFD) == nil, "ipc: oversized request line is refused")
if bigFD >= 0 { close(bigFD) }
try? (String(repeating: "b", count: 4096) + "\n").write(to: bigURL, atomically: true, encoding: .utf8)
let okFD = open(bigURL.path, O_RDONLY)
chk(okFD >= 0 && IPCIO.readLine(okFD)?.count == 4096, "ipc: a 4 KB request line still reads whole")
if okFD >= 0 { close(okFD) }
try? FileManager.default.removeItem(at: bigURL)

// 4) A8: the hub socket is owner-only (0600) and the LOCAL_PEERCRED check reports our own UID.
let sockPath = NSTemporaryDirectory() + "dm-ipc-test-\(getpid()).sock"
unlink(sockPath)
let lfd = dm_ipc_listen(sockPath)
chk(lfd >= 0, "ipc: listen on temp socket")
if lfd >= 0 {
    var st = stat()
    if stat(sockPath, &st) == 0 {
        let perms = st.st_mode & 0o777
        chk(perms == 0o600, "ipc: socket is 0600 (owner-only)", String(format: "%o", perms))
    } else { chk(false, "ipc: stat socket") }
    // AF_UNIX connect queues on the listen backlog, so connect→accept works on one thread.
    let cfd = dm_ipc_connect(sockPath)
    chk(cfd >= 0, "ipc: connect to hub")
    let afd = dm_ipc_accept(lfd)
    chk(afd >= 0, "ipc: accept client")
    if afd >= 0 {
        chk(dm_ipc_peer_uid(afd) == Int32(getuid()),
            "ipc: peer uid == our uid", "\(dm_ipc_peer_uid(afd)) vs \(getuid())")
        // A client that connects and never sends its newline must not wedge the hub's single accept
        // thread: dm_ipc_accept bounds the read (SO_RCVTIMEO 5 s), so readLine gives up with nil.
        let t0 = Date()
        let stalled = IPCIO.readLine(afd)
        let waited = Date().timeIntervalSince(t0)
        chk(stalled == nil && waited >= 4 && waited < 8,
            "ipc: a stalled client times out instead of blocking forever", String(format: "%.1fs", waited))
        close(afd)
    }
    if cfd >= 0 { close(cfd) }
    close(lfd)
    unlink(sockPath)
}

print(fail == 0 ? "ALL IPC TESTS PASSED" : "\(fail) IPC TEST(S) FAILED")
exit(Int32(fail))
