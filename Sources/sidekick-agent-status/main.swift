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

let sequence = "\u{001B}]666;\(termprop)=\(status)\u{001B}\\"

if let data = sequence.data(using: .utf8),
   let tty = FileHandle(forWritingAtPath: "/dev/tty") {
    tty.write(data)
    try? tty.close()
}
