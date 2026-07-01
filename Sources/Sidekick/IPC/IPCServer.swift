import Foundation
import Darwin
import SidekickTelemetryCore

// MARK: - IPC Command Types
nonisolated struct IPCCommand: Codable, Sendable {
    let action: String
    let path: String?
    let old: String?
    let new: String?
    let cwd: String?
    let paneID: String?
    let direction: String?
    let focus: Bool?
    let command: [String]?
    let text: String?
    let key: String?
    let source: String?
    let lines: Int?
    let status: String?
    let match: String?
    let timeoutMS: Int?
    let format: String?
    let worktree: String?
    let force: Bool?
    /// Event-type filter for an `events` subscription (e.g. "agent_state").
    let type: String?
    /// JSON-encoded `TranscriptUsage` blob for a `report_telemetry` call.
    let telemetry: String?

    enum CodingKeys: String, CodingKey {
        case action, path, old, new, cwd, direction, focus, command, text, key, source, lines, status, match, format, worktree, force, type, telemetry
        case paneID = "pane_id"
        case timeoutMS = "timeout_ms"
    }
}

nonisolated struct IPCPaneInfo: Codable, Sendable {
    let paneID: String
    let tabID: String
    let type: String
    let cwd: String?
    let focused: Bool
    let agentStatus: String
    let processID: Int32?

    enum CodingKeys: String, CodingKey {
        case type, cwd, focused
        case paneID = "pane_id"
        case tabID = "tab_id"
        case agentStatus = "agent_status"
        case processID = "process_id"
    }
}

/// One finished shell command, returned by `pane_read` with `format: "json"`.
nonisolated struct IPCCommandRecord: Codable, Sendable {
    let command: String
    let exitCode: Int
    let duration: Double?
    let output: String

    enum CodingKeys: String, CodingKey {
        case command, duration, output
        case exitCode = "exit_code"
    }
}

nonisolated struct IPCResult: Codable, Sendable {
    let panes: [IPCPaneInfo]?
    let pane: IPCPaneInfo?
    let text: String?
    let matched: Bool?
    let commands: [IPCCommandRecord]?

    init(
        panes: [IPCPaneInfo]? = nil,
        pane: IPCPaneInfo? = nil,
        text: String? = nil,
        matched: Bool? = nil,
        commands: [IPCCommandRecord]? = nil
    ) {
        self.panes = panes
        self.pane = pane
        self.text = text
        self.matched = matched
        self.commands = commands
    }
}

nonisolated struct IPCResponse: Codable, Sendable {
    let ok: Bool
    let error: String?
    let accepted: Bool?
    let result: IPCResult?

    init(ok: Bool = true, error: String? = nil, accepted: Bool? = nil, result: IPCResult? = nil) {
        self.ok = ok
        self.error = error
        self.accepted = accepted
        self.result = result
    }
}

nonisolated enum IPCCommandType {
    case ping
    case newTab(cwd: String?)
    case showDiff(paneID: UUID?, path: String, old: String, new: String)
    case agentReady
    case agentBusy
    case agentDone
    case agentIdle
    case paneList
    case paneCurrent(paneID: UUID?)
    case paneSplit(paneID: UUID, direction: SplitDirection, cwd: String?, command: [String]?, focus: Bool, worktree: String?)
    case paneFocus(paneID: UUID)
    case paneClose(paneID: UUID)
    case paneSendText(paneID: UUID, text: String)
    case paneSendKey(paneID: UUID, key: String)
    case paneRead(paneID: UUID, source: String, lines: Int?, json: Bool)
    case waitAgentStatus(paneID: UUID, status: AgentState, timeoutMS: Int)
    case waitOutput(paneID: UUID, match: String, timeoutMS: Int)
    case worktreeRemove(branch: String, cwd: String?, force: Bool)
    case worktreePrune(cwd: String?)
    case reportTelemetry(paneID: UUID, usage: TranscriptUsage)

    static func from(_ command: IPCCommand) -> IPCCommandType? {
        switch command.action {
        case "ping":
            return .ping
        case "new_tab":
            return .newTab(cwd: command.cwd.flatMap(Self.validatedDirectory))
        case "show_diff":
            guard let path = command.path,
                  let old = command.old,
                  let new = command.new,
                  let validPath = Self.validatedDiffPath(path) else { return nil }
            // pane_id is optional: it scopes "approve & remember" grants to the
            // pane the edit hook ran in. Absent (or unparseable) → unscoped.
            return .showDiff(paneID: command.paneID.flatMap(UUID.init(uuidString:)),
                             path: validPath, old: old, new: new)
        case "agent_ready":
            return .agentReady
        case "agent_busy":
            return .agentBusy
        case "agent_done":
            return .agentDone
        case "agent_idle":
            return .agentIdle
        case "pane_list":
            return .paneList
        case "pane_current":
            if let rawPaneID = command.paneID {
                guard let paneID = UUID(uuidString: rawPaneID) else { return nil }
                return .paneCurrent(paneID: paneID)
            }
            return .paneCurrent(paneID: nil)
        case "pane_split":
            guard let paneID = uuid(command.paneID),
                  let direction = splitDirection(command.direction) else { return nil }
            let cwd: String?
            if let requestedCWD = command.cwd {
                guard let validCWD = validatedDirectory(requestedCWD) else { return nil }
                cwd = validCWD
            } else {
                cwd = nil
            }
            if let argv = command.command, argv.isEmpty || argv.count > 256 || argv.contains(where: { $0.count > 32_768 }) {
                return nil
            }
            let worktree: String?
            if let requestedBranch = command.worktree {
                guard let validBranch = validatedBranchName(requestedBranch) else { return nil }
                worktree = validBranch
            } else {
                worktree = nil
            }
            return .paneSplit(
                paneID: paneID,
                direction: direction,
                cwd: cwd,
                command: command.command,
                focus: command.focus ?? true,
                worktree: worktree
            )
        case "pane_focus":
            guard let paneID = uuid(command.paneID) else { return nil }
            return .paneFocus(paneID: paneID)
        case "pane_close":
            guard let paneID = uuid(command.paneID) else { return nil }
            return .paneClose(paneID: paneID)
        case "pane_send_text":
            guard let paneID = uuid(command.paneID), let text = command.text, text.count <= 1_000_000 else { return nil }
            return .paneSendText(paneID: paneID, text: text)
        case "pane_send_key":
            guard let paneID = uuid(command.paneID), let key = command.key, !key.isEmpty else { return nil }
            return .paneSendKey(paneID: paneID, key: key)
        case "pane_read":
            guard let paneID = uuid(command.paneID) else { return nil }
            let source = command.source ?? "visible"
            let format = command.format ?? "text"
            guard source == "visible" || source == "recent",
                  format == "text" || format == "json",
                  command.lines.map({ (1...10_000).contains($0) }) ?? true else { return nil }
            return .paneRead(paneID: paneID, source: source, lines: command.lines, json: format == "json")
        case "wait_agent_status":
            guard let paneID = uuid(command.paneID),
                  let rawStatus = command.status,
                  let status = AgentState(rawValue: rawStatus),
                  let timeout = validTimeout(command.timeoutMS) else { return nil }
            return .waitAgentStatus(paneID: paneID, status: status, timeoutMS: timeout)
        case "wait_output":
            guard let paneID = uuid(command.paneID),
                  let match = command.match, !match.isEmpty, match.count <= 16_384,
                  let timeout = validTimeout(command.timeoutMS) else { return nil }
            return .waitOutput(paneID: paneID, match: match, timeoutMS: timeout)
        case "worktree_remove":
            guard let rawBranch = command.worktree,
                  let branch = validatedBranchName(rawBranch),
                  let cwd = optionalDirectory(command.cwd) else { return nil }
            return .worktreeRemove(branch: branch, cwd: cwd, force: command.force ?? false)
        case "worktree_prune":
            guard let cwd = optionalDirectory(command.cwd) else { return nil }
            return .worktreePrune(cwd: cwd)
        case "report_telemetry":
            guard let paneID = uuid(command.paneID),
                  let json = command.telemetry,
                  let data = json.data(using: .utf8),
                  let usage = try? JSONDecoder().decode(TranscriptUsage.self, from: data) else { return nil }
            return .reportTelemetry(paneID: paneID, usage: usage)
        default:
            return nil
        }
    }

    private static func uuid(_ value: String?) -> UUID? {
        value.flatMap(UUID.init(uuidString:))
    }

    /// Validates an optional `cwd`: nil stays nil (resolve from the active pane
    /// later), a present value must be a real directory. Returns `.some(nil)`
    /// for absent, `.some(dir)` for valid, and `nil` to signal "present but
    /// invalid" so the command is rejected.
    private static func optionalDirectory(_ value: String?) -> String?? {
        guard let value else { return .some(nil) }
        guard let valid = validatedDirectory(value) else { return nil }
        return .some(valid)
    }

    private static func splitDirection(_ value: String?) -> SplitDirection? {
        switch value {
        case "right", "horizontal": return .horizontal
        case "down", "vertical": return .vertical
        default: return nil
        }
    }

    private static func validTimeout(_ value: Int?) -> Int? {
        let timeout = value ?? 30_000
        return (1...3_600_000).contains(timeout) ? timeout : nil
    }

    /// Accepts a git branch name for `pane split --worktree`. Leaves the full
    /// ref-name rules to git itself (an invalid name just fails the command),
    /// but rejects the cases that would be a problem before git sees them: an
    /// empty/oversized value, a leading `-` (would parse as a git option), and
    /// whitespace/control characters (never valid in a ref, and a shell-paste
    /// hazard in logs/UI).
    private static func validatedBranchName(_ branch: String) -> String? {
        guard !branch.isEmpty, branch.count <= 255, !branch.hasPrefix("-") else { return nil }
        let invalid = branch.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar == " " || scalar == "\u{7F}"
        }
        return invalid ? nil : branch
    }

    /// Resolves symlinks and requires an absolute path. The file may not
    /// exist yet (a hook can ask to review the creation of a new file), but
    /// an existing path must be a regular file.
    private static func validatedDiffPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue {
            return nil
        }
        return resolved
    }

    /// Resolves symlinks and requires an absolute path to an existing directory.
    private static func validatedDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return resolved
    }
}

// MARK: - IPC Server Delegate
protocol IPCServerDelegate: AnyObject {
    /// Called on the main thread. The delegate may call `completion`
    /// synchronously, or hold it and respond later (e.g. after the user
    /// accepts/rejects a diff) — the client socket stays open until then.
    func ipcServer(
        _ server: IPCServer,
        didReceiveCommand command: IPCCommandType,
        completion: @escaping @Sendable (IPCResponse) -> Void
    )
}

/// A thread-safe "fire exactly once" latch. `claim()` returns true only for the
/// first caller. Used to guard a deferred IPC completion against a delegate that
/// invokes it more than once: a reference-captured latch is data-race free where
/// a captured `var Bool` is not, so this satisfies strict concurrency's
/// mutable-capture check (prep for the Swift 6 migration).
nonisolated final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - IPC Server
// @unchecked Sendable: mutable state (`isRunning`) is guarded by `stateLock`;
// `serverFD` is assigned once at startup before the accept loop reads it. The
// accept loop runs on a background thread and per-connection work hops to the
// main queue. Marked explicitly to prep for the Swift 6 strict-concurrency
// migration without flipping the language mode yet.
nonisolated final class IPCServer: @unchecked Sendable {
    private let socketURL: URL
    private var serverFD: Int32 = -1
    private let stateLock = NSLock()
    private var isRunning = false
    weak var delegate: IPCServerDelegate?

    /// Requests larger than this are rejected to bound memory per client.
    /// Sized to fit show_diff payloads (two ~4MB file bodies, JSON-escaped).
    private static let maxRequestBytes = 16 * 1024 * 1024

    static let shared = IPCServer()

    private init() {
        // Socket path: ~/.config/sidekick/sidekick.sock
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = homeDirectory.appendingPathComponent(".config/sidekick")
        socketURL = configDirectory.appendingPathComponent("sidekick.sock")
    }

    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }

        setupSocketDirectory()
        cleanupExistingSocket()

        guard let fd = bindAndListen() else { return }
        serverFD = fd
        isRunning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop(serverFD: fd)
        }
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        isRunning = false
        // Closing the listening socket makes the blocked accept() return -1,
        // which lets the accept loop observe isRunning == false and exit.
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private var shouldKeepRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    private func setupSocketDirectory() {
        let configDirectory = socketURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory only applies permissions on creation; enforce them
            // even when the directory already existed.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configDirectory.path
            )
        } catch {
            Log.debug("IPCServer: Failed to prepare config directory: \(error)")
        }
    }

    private func cleanupExistingSocket() {
        if FileManager.default.fileExists(atPath: socketURL.path) {
            do {
                try FileManager.default.removeItem(at: socketURL)
            } catch {
                Log.debug("IPCServer: Failed to remove existing socket: \(error)")
            }
        }
    }

    private func bindAndListen() -> Int32? {
        let socketPath = socketURL.path

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD != -1 else {
            Log.debug("IPCServer: Failed to create socket")
            return nil
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            Log.debug("IPCServer: Socket path too long")
            close(socketFD)
            return nil
        }

        socketPath.withCString { pathCString in
            withUnsafeMutablePointer(to: &address.sun_path.0) { pathPtr in
                strncpy(pathPtr, pathCString, maxPathLength - 1)
                pathPtr[maxPathLength - 1] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult != -1 else {
            Log.debug("IPCServer: Failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return nil
        }

        // Restrict the socket itself to the owner, independent of directory perms.
        chmod(socketPath, 0o600)

        guard listen(socketFD, 5) != -1 else {
            Log.debug("IPCServer: Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return nil
        }

        Log.debug("IPCServer: Listening on \(socketPath)")
        return socketFD
    }

    private func acceptLoop(serverFD: Int32) {
        while shouldKeepRunning {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD != -1 else {
                if shouldKeepRunning {
                    Log.debug("IPCServer: Failed to accept connection: \(String(cString: strerror(errno)))")
                    continue
                }
                break
            }

            guard peerIsCurrentUser(clientFD) else {
                Log.debug("IPCServer: Rejecting connection from other user")
                close(clientFD)
                continue
            }

            // Responses can be deferred (diff approval), so the client may be
            // gone by the time we write. Without this, write() to a closed
            // peer raises SIGPIPE and kills the app; with it, write() just
            // returns EPIPE.
            var noSigpipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD: clientFD)
            }
        }
    }

    /// Verifies the connecting peer runs as the same UID as this process.
    private func peerIsCurrentUser(_ clientFD: Int32) -> Bool {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(clientFD, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0 else {
            return false
        }
        return credentials.cr_uid == getuid()
    }

    private func handleClient(clientFD: Int32) {
        // Read a single newline-terminated request. The client may keep its
        // write side open while waiting for the response, so reading to EOF
        // would deadlock.
        guard let requestData = readLine(from: clientFD) else {
            Log.debug("IPCServer: Failed to read command")
            close(clientFD)
            return
        }

        guard let commandString = String(data: requestData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !commandString.isEmpty,
              let commandData = commandString.data(using: .utf8) else {
            sendResponse(IPCResponse(ok: false, error: "Empty or invalid request"), to: clientFD)
            close(clientFD)
            return
        }

        let command: IPCCommand
        do {
            command = try JSONDecoder().decode(IPCCommand.self, from: commandData)
        } catch {
            Log.debug("IPCServer: Failed to parse command: \(error)")
            sendResponse(IPCResponse(ok: false, error: "Invalid JSON command"), to: clientFD)
            close(clientFD)
            return
        }

        // `events` is a long-lived stream, not a request/response: hand the
        // socket to the broadcaster and block this connection thread reading it
        // so the client's hang-up unblocks promptly for cleanup. The reader is
        // the sole owner of close() (see EventBroadcaster).
        if command.action == "events" {
            EventBroadcaster.shared.addSubscriber(clientFD, filter: Self.eventFilter(from: command))
            var drain = [UInt8](repeating: 0, count: 256)
            while read(clientFD, &drain, drain.count) > 0 { /* clients don't send */ }
            EventBroadcaster.shared.removeSubscriber(clientFD)
            return
        }

        guard let commandType = IPCCommandType.from(command) else {
            Log.debug("IPCServer: Unknown or invalid command: \(command.action)")
            sendResponse(IPCResponse(ok: false, error: "Unknown or invalid command: \(command.action)"), to: clientFD)
            close(clientFD)
            return
        }

        // Execute on the main thread without blocking this queue; the
        // response is written (and the socket closed) once the delegate calls
        // the completion — which may be deferred (e.g. diff approval).
        DispatchQueue.main.async { [weak self] in
            // Delivered on the main queue, so the main-actor `delegate` access
            // below is safe to run synchronously.
            MainActor.assumeIsolated {
                guard let self = self else {
                    close(clientFD)
                    return
                }

                guard let delegate = self.delegate else {
                    self.sendResponse(IPCResponse(ok: false, error: "No delegate"), to: clientFD)
                    close(clientFD)
                    return
                }

                let responded = OnceLatch()
                delegate.ipcServer(self, didReceiveCommand: commandType) { [weak self] response in
                    guard responded.claim() else { return }
                    // This completion runs on the main thread (immediately or
                    // deferred by a wait/approval). A response larger than the
                    // socket send buffer to a client that stops draining would
                    // stall the write — so it never happens on main.
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.sendResponse(response, to: clientFD)
                        close(clientFD)
                    }
                }
            }
        }
    }

    /// Builds an `EventFilter` from an `events` subscribe request. A pane id is
    /// lowercased to match the emitted form; a present-but-unmatched pane or
    /// type simply yields no events (only the `hello` marker), which reads as
    /// "nothing matched" rather than silently broadcasting everything.
    private static func eventFilter(from command: IPCCommand) -> EventFilter {
        let paneID = command.paneID.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let type = command.type.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        return EventFilter(paneID: paneID, type: type)
    }

    private func readLine(from clientFD: Int32) -> Data? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while request.count < Self.maxRequestBytes {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead <= 0 {
                // EOF or error: accept what we have if the client closed
                // its write side instead of sending a trailing newline.
                return request.isEmpty ? nil : request
            }
            request.append(contentsOf: buffer[0..<bytesRead])
            if buffer[0..<bytesRead].contains(UInt8(ascii: "\n")) {
                return request
            }
        }
        return nil
    }

    /// A client that connects, sends a request, and stops draining its socket
    /// gets this long for the response before we give up and close on it —
    /// bounds how long a response write can pin a worker thread.
    private static let responseWriteTimeout: DispatchTimeInterval = .seconds(10)

    private func sendResponse(_ response: IPCResponse, to clientFD: Int32) {
        let responseData: Data
        if let encoded = try? JSONEncoder().encode(response) {
            responseData = encoded
        } else {
            responseData = Data("{\"ok\":false}".utf8)
        }

        // The fd is blocking, and a blocking write() past the kernel send
        // buffer stalls until the client drains — indefinitely, for a client
        // that never does. Flip it non-blocking and wait for writability in
        // poll() against a deadline instead, so the worst a wedged client
        // costs is `responseWriteTimeout` on a background thread.
        let flags = fcntl(clientFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
        }
        let deadline = DispatchTime.now() + Self.responseWriteTimeout

        var payload = responseData
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var remaining = payload.count
            var cursor = baseAddress
            while remaining > 0 {
                let written = write(clientFD, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                    continue
                }
                guard written < 0, errno == EAGAIN || errno == EINTR else { return }
                let nowNanos = DispatchTime.now().uptimeNanoseconds
                guard deadline.uptimeNanoseconds > nowNanos else { return }
                let waitMillis = Int32(min((deadline.uptimeNanoseconds - nowNanos) / 1_000_000, 1_000))
                var pfd = pollfd(fd: clientFD, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, max(waitMillis, 1))
                if ready < 0 && errno != EINTR { return }
                if ready > 0 && (pfd.revents & Int16(POLLOUT | POLLHUP | POLLERR)) == 0 { return }
            }
        }
    }
}
