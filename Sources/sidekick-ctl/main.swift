import Foundation
import Darwin

@main
struct SidekickCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { usageAndExit() }

        let socketPath = ProcessInfo.processInfo.environment["SIDEKICK_SOCKET_PATH"]
            ?? NSString("~/.config/sidekick/sidekick.sock").expandingTildeInPath
        let client = IPCClient(socketPath: socketPath)

        do {
            let request = try makeRequest(args)
            guard let response = client.send(request) else {
                fail("Sidekick is not responding")
            }
            guard response["ok"] as? Bool == true else {
                fail(response["error"] as? String ?? "Sidekick rejected the request")
            }

            if args.first == "ping" {
                print("Sidekick is running")
            } else if args.prefix(2).elementsEqual(["pane", "read"]),
                      let result = response["result"] as? [String: Any],
                      let text = result["text"] as? String {
                print(text)
            } else if shouldPrintJSON(args) {
                printJSON(response)
            } else if args.prefix(2).elementsEqual(["wait", "agent-status"])
                        || args.prefix(2).elementsEqual(["wait", "output"]) {
                let matched = (response["result"] as? [String: Any])?["matched"] as? Bool ?? false
                if !matched { exit(1) }
            }
        } catch let error as CLIError {
            fail(error.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func makeRequest(_ args: [String]) throws -> [String: Any] {
        switch args[0] {
        case "ping":
            return ["action": "ping"]
        case "new-tab":
            return ["action": "new_tab", "cwd": args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath]
        case "open-diff":
            guard args.count == 2 else { throw CLIError("open-diff requires a file path") }
            return ["action": "show_diff", "path": args[1], "old": "", "new": ""]
        case "agent-ready": return ["action": "agent_ready"]
        case "agent-busy": return ["action": "agent_busy"]
        case "agent-done": return ["action": "agent_done"]
        case "agent-idle": return ["action": "agent_idle"]
        case "pane":
            return try paneRequest(Array(args.dropFirst()))
        case "wait":
            return try waitRequest(Array(args.dropFirst()))
        default:
            throw CLIError("Unknown command: \(args[0])")
        }
    }

    private static func paneRequest(_ args: [String]) throws -> [String: Any] {
        guard let subcommand = args.first else { throw CLIError("pane requires a subcommand") }
        switch subcommand {
        case "list":
            return ["action": "pane_list"]
        case "current":
            var request: [String: Any] = ["action": "pane_current"]
            if let paneID = ProcessInfo.processInfo.environment["SIDEKICK_PANE_ID"] {
                request["pane_id"] = paneID
            }
            return request
        case "split":
            guard args.count >= 2 else { throw CLIError("pane split requires a pane ID") }
            var request: [String: Any] = [
                "action": "pane_split",
                "pane_id": args[1],
                "direction": "right",
                "focus": true,
            ]
            var index = 2
            while index < args.count {
                switch args[index] {
                case "--direction":
                    index += 1
                    guard index < args.count else { throw CLIError("--direction requires right or down") }
                    request["direction"] = args[index]
                case "--cwd":
                    index += 1
                    guard index < args.count else { throw CLIError("--cwd requires a directory") }
                    request["cwd"] = NSString(string: args[index]).expandingTildeInPath
                case "--no-focus":
                    request["focus"] = false
                case "--exec":
                    let command = Array(args.dropFirst(index + 1))
                    guard !command.isEmpty else { throw CLIError("--exec requires a command") }
                    request["command"] = command
                    index = args.count
                    continue
                default:
                    throw CLIError("Unknown pane split option: \(args[index])")
                }
                index += 1
            }
            return request
        case "focus", "close":
            guard args.count == 2 else { throw CLIError("pane \(subcommand) requires a pane ID") }
            return ["action": "pane_\(subcommand)", "pane_id": args[1]]
        case "send-text":
            guard args.count >= 3 else { throw CLIError("pane send-text requires a pane ID and text") }
            return ["action": "pane_send_text", "pane_id": args[1], "text": args.dropFirst(2).joined(separator: " ")]
        case "send-key":
            guard args.count == 3 else { throw CLIError("pane send-key requires a pane ID and key") }
            return ["action": "pane_send_key", "pane_id": args[1], "key": args[2]]
        case "run":
            guard args.count >= 3 else { throw CLIError("pane run requires a pane ID and command text") }
            return ["action": "pane_send_text", "pane_id": args[1], "text": args.dropFirst(2).joined(separator: " ") + "\r"]
        case "read":
            guard args.count >= 2 else { throw CLIError("pane read requires a pane ID") }
            var request: [String: Any] = ["action": "pane_read", "pane_id": args[1], "source": "visible"]
            var index = 2
            while index < args.count {
                switch args[index] {
                case "--source":
                    index += 1
                    guard index < args.count else { throw CLIError("--source requires visible or recent") }
                    request["source"] = args[index]
                case "--lines":
                    index += 1
                    guard index < args.count, let lines = Int(args[index]) else { throw CLIError("--lines requires an integer") }
                    request["lines"] = lines
                default:
                    throw CLIError("Unknown pane read option: \(args[index])")
                }
                index += 1
            }
            return request
        default:
            throw CLIError("Unknown pane subcommand: \(subcommand)")
        }
    }

    private static func waitRequest(_ args: [String]) throws -> [String: Any] {
        guard args.count >= 3 else { throw CLIError("wait requires agent-status/output, a pane ID, and a value") }
        var request: [String: Any] = ["pane_id": args[1], "timeout_ms": 30_000]
        switch args[0] {
        case "agent-status":
            request["action"] = "wait_agent_status"
            request["status"] = args[2]
        case "output":
            request["action"] = "wait_output"
            request["match"] = args[2]
        default:
            throw CLIError("Unknown wait target: \(args[0])")
        }
        var index = 3
        while index < args.count {
            guard args[index] == "--timeout", index + 1 < args.count, let timeout = Int(args[index + 1]) else {
                throw CLIError("wait supports only --timeout <milliseconds>")
            }
            request["timeout_ms"] = timeout
            index += 2
        }
        return request
    }

    private static func shouldPrintJSON(_ args: [String]) -> Bool {
        args.first == "pane" && args.count > 1 && ["list", "current", "split", "focus"].contains(args[1])
    }

    private static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return }
        print(string)
    }

    private static func usageAndExit() -> Never {
        print("""
        Usage: sidekick-ctl <command>
          ping | new-tab [cwd] | open-diff <file>
          agent-ready | agent-busy | agent-done | agent-idle
          pane list | current
          pane split <pane-id> [--direction right|down] [--cwd dir] [--no-focus] [--exec command args...]
          pane focus|close <pane-id>
          pane send-text <pane-id> <text> | send-key <pane-id> <key> | run <pane-id> <command>
          pane read <pane-id> [--source visible|recent] [--lines count]
          wait agent-status <pane-id> <idle|working|ready|done> [--timeout ms]
          wait output <pane-id> <text> [--timeout ms]
        """)
        exit(1)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

private struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private final class IPCClient {
    private let socketPath: String
    init(socketPath: String) { self.socketPath = socketPath }

    func send(_ command: [String: Any]) -> [String: Any]? {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8CString.count <= maxPathLength else { return nil }
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, path, maxPathLength - 1)
                destination[maxPathLength - 1] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0,
              var payload = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        payload.append(UInt8(ascii: "\n"))
        let wroteAll = payload.withUnsafeBytes { bytes -> Bool in
            guard var cursor = bytes.baseAddress else { return false }
            var remaining = bytes.count
            while remaining > 0 {
                let count = write(socketFD, cursor, remaining)
                guard count > 0 else { return false }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
            return true
        }
        guard wroteAll else { return nil }
        shutdown(socketFD, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16 * 1024 * 1024 {
            let count = read(socketFD, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(UInt8(ascii: "\n")) { break }
        }
        return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    }
}
