import Foundation
import Darwin

/// Blocking, line-delimited JSON socket I/O for the hub (used off the main actor). One JSON object
/// per line, `\n`-terminated — the same framing the `owl-monitor` CLI speaks.
enum IPCIO {
    /// Ceiling on one request line. A real request is a few hundred bytes (a command, a path and a
    /// couple of flags); without a cap a runaway or hostile peer could grow this buffer until the
    /// app runs out of memory. Only the hub reads requests through here — the CLI reads the hub's
    /// replies with its own loop (`roundtrip`), so long build-log lines are unaffected.
    static let maxRequestBytes = 64 * 1024

    /// Read one `\n`-terminated request. nil on EOF before any byte, on a line over
    /// `maxRequestBytes`, or when the peer stalls past the socket's receive timeout (set in
    /// `dm_ipc_accept`) — all of which the hub answers as a bad request.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            data.append(byte)
            if data.count > maxRequestBytes { return nil }
        }
        return data.isEmpty ? nil : data
    }

    static func write(_ fd: Int32, _ message: IPCMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = Darwin.write(fd, base, raw.count) }
        }
    }
}
