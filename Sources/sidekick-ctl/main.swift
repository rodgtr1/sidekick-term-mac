import Foundation

@main
struct SidekickCtl {
    static func main() {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            print("Usage: sidekick-ctl <command> [args...]")
            print("Commands:")
            print("  ping                - Check if sidekick is running")
            print("  new-tab [cwd]       - Create a new terminal tab")
            print("  open-diff <file>    - Open diff view for file")
            print("  agent-ready         - Mark agent as ready (waiting for user)")
            print("  agent-busy          - Mark agent as busy (working)")
            print("  agent-done          - Mark agent as done (finished last run)")
            print("  agent-idle          - Mark agent as idle (no activity)")
            exit(1)
        }

        let command = args[1]
        let socketPath = NSString("~/.config/sidekick/sidekick.sock").expandingTildeInPath

        let client = IPCClient(socketPath: socketPath)

        switch command {
        case "ping":
            if client.ping() {
                print("Sidekick is running")
            } else {
                print("Sidekick is not responding")
                exit(1)
            }

        case "new-tab":
            let cwd = args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath
            if client.newTab(cwd: cwd) {
                print("New tab created")
            } else {
                print("Failed to create new tab")
                exit(1)
            }

        case "open-diff":
            guard args.count > 2 else {
                print("Error: open-diff requires a file path")
                exit(1)
            }
            let filePath = args[2]
            if client.openDiff(filePath: filePath) {
                print("Diff opened")
            } else {
                print("Failed to open diff")
                exit(1)
            }

        case "agent-ready":
            if client.agentReady() {
                print("Agent marked as ready")
            } else {
                print("Failed to mark agent as ready")
                exit(1)
            }

        case "agent-busy":
            if client.agentBusy() {
                print("Agent marked as busy")
            } else {
                print("Failed to mark agent as busy")
                exit(1)
            }

        case "agent-done":
            if client.agentDone() {
                print("Agent marked as done")
            } else {
                print("Failed to mark agent as done")
                exit(1)
            }

        case "agent-idle":
            if client.agentIdle() {
                print("Agent marked as idle")
            } else {
                print("Failed to mark agent as idle")
                exit(1)
            }

        default:
            print("Unknown command: \(command)")
            exit(1)
        }
    }
}

class IPCClient {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func ping() -> Bool {
        return sendCommand(["action": "ping"])
    }

    func newTab(cwd: String) -> Bool {
        return sendCommand(["action": "new_tab", "cwd": cwd])
    }

    func openDiff(filePath: String) -> Bool {
        return sendCommand(["action": "show_diff", "path": filePath, "old": "", "new": ""])
    }

    func agentReady() -> Bool {
        return sendCommand(["action": "agent_ready"])
    }

    func agentBusy() -> Bool {
        return sendCommand(["action": "agent_busy"])
    }

    func agentDone() -> Bool {
        return sendCommand(["action": "agent_done"])
    }

    func agentIdle() -> Bool {
        return sendCommand(["action": "agent_idle"])
    }

    private func sendCommand(_ command: [String: String]) -> Bool {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        socketPath.withCString { pathCString in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { pathPtr in
                _ = strcpy(pathPtr, pathCString)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else { return false }

        do {
            let data = try JSONSerialization.data(withJSONObject: command)
            var commandString = String(data: data, encoding: .utf8) ?? ""
            commandString += "\n" // Add newline for line-based protocol

            let written = commandString.data(using: .utf8)?.withUnsafeBytes { bytes in
                write(socketFD, bytes.bindMemory(to: UInt8.self).baseAddress, commandString.utf8.count)
            } ?? 0

            guard written == commandString.utf8.count else { return false }

            // Read response
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }

            let bytesRead = read(socketFD, buffer, 1024)
            guard bytesRead > 0 else { return false }

            let responseData = Data(bytes: buffer, count: bytesRead)
            guard let responseString = String(data: responseData, encoding: .utf8),
                  let responseJson = responseString.data(using: .utf8),
                  let response = try? JSONSerialization.jsonObject(with: responseJson) as? [String: Any],
                  let ok = response["ok"] as? Bool else {
                return false
            }

            return ok
        } catch {
            return false
        }
    }
}
