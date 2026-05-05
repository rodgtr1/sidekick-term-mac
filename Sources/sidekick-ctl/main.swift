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
        return sendCommand(["command": "ping"])
    }

    func newTab(cwd: String) -> Bool {
        return sendCommand(["command": "new-tab", "cwd": cwd])
    }

    func openDiff(filePath: String) -> Bool {
        return sendCommand(["command": "open-diff", "file": filePath])
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
            let written = data.withUnsafeBytes { bytes in
                write(socketFD, bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            return written == data.count
        } catch {
            return false
        }
    }
}