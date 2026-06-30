import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The Unix-socket path Sidekick listens on: `$SIDEKICK_SOCKET_PATH` when set
/// (Sidekick exports it into every pane), else the default under `~/.config`.
public func defaultSidekickSocketPath() -> String {
    ProcessInfo.processInfo.environment["SIDEKICK_SOCKET_PATH"]
        ?? NSString("~/.config/sidekick/sidekick.sock").expandingTildeInPath
}

/// Shared client for Sidekick's control socket, used by `sidekick-ctl`,
/// `sidekick-mcp`, and `sidekick-telemetry`. Previously each helper carried its
/// own near-identical copy of the connect/write/read plumbing — with subtle
/// drift (an fd leak on the path-too-long branch, and a read loop that stopped at
/// the first newline and so truncated multi-line replies like `pane_read`
/// scrollback). This is the single, correct implementation.
public final class SidekickIPCClient {
    private let socketPath: String

    public init(socketPath: String = defaultSidekickSocketPath()) {
        self.socketPath = socketPath
    }

    /// Connects and writes `command` as one newline-framed JSON line. When
    /// `halfCloseWrite` is true the write side is shut so the server sees EOF and
    /// replies (request/response); streaming callers keep it open so the server's
    /// read side can detect their disconnect. Returns the connected FD (the caller
    /// owns `close`) or nil — and never leaks the FD on a failure path.
    public func openConnection(_ command: [String: Any], halfCloseWrite: Bool) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8CString.count <= maxPathLength else { close(fd); return nil }
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, path, maxPathLength - 1)
                destination[maxPathLength - 1] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0,
              var payload = try? JSONSerialization.data(withJSONObject: command) else { close(fd); return nil }
        payload.append(UInt8(ascii: "\n"))
        let wroteAll = payload.withUnsafeBytes { bytes -> Bool in
            guard var cursor = bytes.baseAddress else { return false }
            var remaining = bytes.count
            while remaining > 0 {
                let count = write(fd, cursor, remaining)
                guard count > 0 else { return false }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
            return true
        }
        guard wroteAll else { close(fd); return nil }
        if halfCloseWrite { shutdown(fd, SHUT_WR) }
        return fd
    }

    /// One request → one reply. Reads to EOF (the server closes after a single
    /// response) rather than stopping at the first newline, so a reply containing
    /// embedded newlines — e.g. `pane_read` output split across reads — isn't
    /// truncated. Returns the parsed JSON object, or nil if unreachable/invalid.
    public func send(_ command: [String: Any]) -> [String: Any]? {
        guard let fd = openConnection(command, halfCloseWrite: true) else { return nil }
        defer { close(fd) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16 * 1024 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }   // EOF: the server closed after its single reply.
            response.append(contentsOf: buffer[0..<count])
        }
        return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    }

    /// Connect, write one command, close. No reply expected (telemetry reports).
    @discardableResult
    public func sendFireAndForget(_ command: [String: Any]) -> Bool {
        guard let fd = openConnection(command, halfCloseWrite: true) else { return false }
        close(fd)
        return true
    }

    /// Streams newline-delimited reply lines to `onLine` until the server hangs
    /// up. Returns false only if the connection couldn't be established.
    public func stream(_ command: [String: Any], onLine: (Data) -> Void) -> Bool {
        guard let fd = openConnection(command, halfCloseWrite: false) else { return false }
        defer { close(fd) }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                onLine(Data(pending[pending.startIndex...newline]))
                pending = pending[pending.index(after: newline)...]
            }
        }
        return true
    }
}
