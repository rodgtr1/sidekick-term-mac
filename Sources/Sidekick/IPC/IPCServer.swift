import Foundation
import Darwin

// MARK: - IPC Command Types
struct IPCCommand: Codable {
    let action: String
    let path: String?
    let old: String?
    let new: String?
    let cwd: String?
}

struct IPCResponse: Codable {
    let ok: Bool
    let error: String?
    let accepted: Bool?

    init(ok: Bool = true, error: String? = nil, accepted: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.accepted = accepted
    }
}

enum IPCCommandType {
    case ping
    case newTab(cwd: String?)
    case showDiff(path: String, old: String, new: String)
    case agentReady
    case agentBusy
    case agentDone
    case agentIdle

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
            return .showDiff(path: validPath, old: old, new: new)
        case "agent_ready":
            return .agentReady
        case "agent_busy":
            return .agentBusy
        case "agent_done":
            return .agentDone
        case "agent_idle":
            return .agentIdle
        default:
            return nil
        }
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
        completion: @escaping (IPCResponse) -> Void
    )
}

// MARK: - IPC Server
class IPCServer {
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
            print("IPCServer: Failed to prepare config directory: \(error)")
        }
    }

    private func cleanupExistingSocket() {
        if FileManager.default.fileExists(atPath: socketURL.path) {
            do {
                try FileManager.default.removeItem(at: socketURL)
            } catch {
                print("IPCServer: Failed to remove existing socket: \(error)")
            }
        }
    }

    private func bindAndListen() -> Int32? {
        let socketPath = socketURL.path

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD != -1 else {
            print("IPCServer: Failed to create socket")
            return nil
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            print("IPCServer: Socket path too long")
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
            print("IPCServer: Failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return nil
        }

        // Restrict the socket itself to the owner, independent of directory perms.
        chmod(socketPath, 0o600)

        guard listen(socketFD, 5) != -1 else {
            print("IPCServer: Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return nil
        }

        print("IPCServer: Listening on \(socketPath)")
        return socketFD
    }

    private func acceptLoop(serverFD: Int32) {
        while shouldKeepRunning {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD != -1 else {
                if shouldKeepRunning {
                    print("IPCServer: Failed to accept connection: \(String(cString: strerror(errno)))")
                    continue
                }
                break
            }

            guard peerIsCurrentUser(clientFD) else {
                print("IPCServer: Rejecting connection from other user")
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
            print("IPCServer: Failed to read command")
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
            print("IPCServer: Failed to parse command: \(error)")
            sendResponse(IPCResponse(ok: false, error: "Invalid JSON command"), to: clientFD)
            close(clientFD)
            return
        }

        guard let commandType = IPCCommandType.from(command) else {
            print("IPCServer: Unknown or invalid command: \(command.action)")
            sendResponse(IPCResponse(ok: false, error: "Unknown or invalid command: \(command.action)"), to: clientFD)
            close(clientFD)
            return
        }

        // Execute on the main thread without blocking this queue; the
        // response is written (and the socket closed) once the delegate calls
        // the completion — which may be deferred (e.g. diff approval).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                close(clientFD)
                return
            }

            guard let delegate = self.delegate else {
                self.sendResponse(IPCResponse(ok: false, error: "No delegate"), to: clientFD)
                close(clientFD)
                return
            }

            var responded = false
            delegate.ipcServer(self, didReceiveCommand: commandType) { [weak self] response in
                guard !responded else { return }
                responded = true
                self?.sendResponse(response, to: clientFD)
                close(clientFD)
            }
        }
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

    private func sendResponse(_ response: IPCResponse, to clientFD: Int32) {
        let responseData: Data
        if let encoded = try? JSONEncoder().encode(response) {
            responseData = encoded
        } else {
            responseData = Data("{\"ok\":false}".utf8)
        }

        var payload = responseData
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var remaining = payload.count
            var cursor = baseAddress
            while remaining > 0 {
                let written = write(clientFD, cursor, remaining)
                guard written > 0 else { return }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
    }
}
