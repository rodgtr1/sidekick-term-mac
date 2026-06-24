import Foundation

private let termprop = "vte.ext.sidekick.agent"

let status: String
switch CommandLine.arguments.dropFirst().first {
case "busy", "working", "running":
    status = "busy"
case "ready", "prompt", "waiting", "needs-user", "needs_user":
    status = "ready"
case "done", "finished", "complete":
    status = "done"
case "idle", "clear", "reset":
    status = "idle"
default:
    FileHandle.standardError.write(Data("usage: sidekick-agent-status busy|ready|done|idle\n".utf8))
    exit(2)
}

/// Reads the `message` from a Claude Code hook payload on stdin, if present.
/// Hooks always receive JSON on stdin, so we only read when stdin is a pipe
/// (never a TTY, which would block an interactive invocation).
private func hookMessage() -> String? {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = json["message"] as? String else { return nil }
    return message
}

// Claude Code's Notification hook fires both for genuine permission requests
// ("Claude needs your permission to use Bash") AND for the idle reminder
// ("Claude is waiting for your input") that arrives ~60s after a turn ends.
// The idle reminder must not flip a finished agent back to "Needs input", so
// when reporting `ready` we inspect the hook payload and suppress that case —
// leaving the pane in whatever state the Stop/Done hook last set.
if status == "ready",
   let message = hookMessage()?.lowercased(),
   message.contains("waiting for your input") {
    exit(0)
}

let sequence = "\u{001B}]666;\(termprop)=\(status)\u{001B}\\"

if let data = sequence.data(using: .utf8),
   let tty = FileHandle(forWritingAtPath: "/dev/tty") {
    tty.write(data)
    try? tty.close()
}
