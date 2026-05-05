import Foundation
import Network

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

    static func from(_ command: IPCCommand) -> IPCCommandType? {
        switch command.action {
        case "ping":
            return .ping
        case "new_tab":
            return .newTab(cwd: command.cwd)
        case "show_diff":
            guard let path = command.path,
                  let old = command.old,
                  let new = command.new else { return nil }
            return .showDiff(path: path, old: old, new: new)
        case "agent_ready":
            return .agentReady
        case "agent_busy":
            return .agentBusy
        default:
            return nil
        }
    }
}

// MARK: - IPC Server Delegate
protocol IPCServerDelegate: AnyObject {
    func ipcServer(_ server: IPCServer, didReceiveCommand command: IPCCommandType) -> IPCResponse
}

// MARK: - IPC Server
class IPCServer {
    private var listener: NWListener?
    private let socketURL: URL
    weak var delegate: IPCServerDelegate?

    static let shared = IPCServer()

    private init() {
        // Socket path: ~/.config/sidekick/sidekick.sock
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = homeDirectory.appendingPathComponent(".config/sidekick")
        socketURL = configDirectory.appendingPathComponent("sidekick.sock")
    }

    func start() {
        setupSocketDirectory()
        cleanupExistingSocket()
        startListener()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func setupSocketDirectory() {
        let configDirectory = socketURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            print("IPCServer: Failed to create config directory: \(error)")
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

    private func startListener() {
        // Use Unix domain socket with file system
        startUnixSocketServer()
    }

    private func startUnixSocketServer() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.runUnixSocketServer()
        }
    }

    private func runUnixSocketServer() {
        let socketPath = socketURL.path

        // Create Unix domain socket
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD != -1 else {
            print("IPCServer: Failed to create socket")
            return
        }

        defer {
            close(socketFD)
        }

        // Prepare socket address
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            print("IPCServer: Socket path too long")
            return
        }

        // Copy path into sun_path using strncpy
        socketPath.withCString { pathCString in
            withUnsafeMutablePointer(to: &address.sun_path.0) { pathPtr in
                strncpy(pathPtr, pathCString, maxPathLength - 1)
                pathPtr[maxPathLength - 1] = 0 // Ensure null termination
            }
        }

        // Bind socket
        let addressPointer = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }

        let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard bind(socketFD, addressPointer, addressSize) != -1 else {
            print("IPCServer: Failed to bind socket: \(String(cString: strerror(errno)))")
            return
        }

        // Listen for connections
        guard listen(socketFD, 5) != -1 else {
            print("IPCServer: Failed to listen on socket: \(String(cString: strerror(errno)))")
            return
        }

        print("IPCServer: Listening on \(socketPath)")

        // Accept connections
        while true {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD != -1 else {
                print("IPCServer: Failed to accept connection: \(String(cString: strerror(errno)))")
                continue
            }

            // Handle client in background
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD: clientFD)
            }
        }
    }

    private func handleClient(clientFD: Int32) {
        defer {
            close(clientFD)
        }

        // Create file handle for easier reading/writing
        let fileHandle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)

        do {
            // Read command (line-based)
            guard let data = try fileHandle.readToEnd(),
                  let commandString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !commandString.isEmpty else {
                print("IPCServer: Failed to read command")
                return
            }

            // Parse JSON command
            let command: IPCCommand
            do {
                command = try JSONDecoder().decode(IPCCommand.self, from: commandString.data(using: .utf8)!)
            } catch {
                print("IPCServer: Failed to parse command: \(error)")
                let errorResponse = IPCResponse(ok: false, error: "Invalid JSON command")
                sendResponse(errorResponse, to: fileHandle)
                return
            }

            // Convert to command type
            guard let commandType = IPCCommandType.from(command) else {
                print("IPCServer: Unknown command: \(command.action)")
                let errorResponse = IPCResponse(ok: false, error: "Unknown command: \(command.action)")
                sendResponse(errorResponse, to: fileHandle)
                return
            }

            // Execute command on main thread
            DispatchQueue.main.sync { [weak self] in
                guard let self = self else { return }

                let response: IPCResponse
                if let delegate = self.delegate {
                    response = delegate.ipcServer(self, didReceiveCommand: commandType)
                } else {
                    response = IPCResponse(ok: false, error: "No delegate")
                }

                self.sendResponse(response, to: fileHandle)
            }

        } catch {
            print("IPCServer: Error handling client: \(error)")
        }
    }

    private func sendResponse(_ response: IPCResponse, to fileHandle: FileHandle) {
        do {
            let responseData = try JSONEncoder().encode(response)
            var responseString = String(data: responseData, encoding: .utf8) ?? "{\"ok\":false}"
            responseString += "\n"

            fileHandle.write(responseString.data(using: .utf8)!)
        } catch {
            print("IPCServer: Failed to send response: \(error)")
        }
    }
}