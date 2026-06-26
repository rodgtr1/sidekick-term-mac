import Foundation

/// Claude Code PreToolUse hook: intercepts Write/Edit/MultiEdit tool calls,
/// shows the proposed change in Sidekick (via the IPC socket), and blocks
/// until the user accepts (exit 0) or rejects (exit 2) the edit.
///
/// Fails open: if Sidekick isn't running, the payload can't be parsed, or
/// the file is too large to review, the edit is allowed silently.

let maxReviewBytes = 4 * 1024 * 1024
/// Serialized requests above this are skipped instead of sent: Sidekick's
/// IPC server caps request size, and hitting that cap mid-stream looks like
/// a hung connection rather than a clean skip.
let maxRequestBytes = 12 * 1024 * 1024

/// Set SIDEKICK_HOOK_DEBUG=1 to trace why the hook allowed an edit.
let debugEnabled = ProcessInfo.processInfo.environment["SIDEKICK_HOOK_DEBUG"] == "1"
func debugLog(_ message: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("sidekick-hook: \(message)\n".utf8))
}

// MARK: - Read the PreToolUse payload from stdin

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any],
      let toolName = payload["tool_name"] as? String,
      let toolInput = payload["tool_input"] as? [String: Any],
      let filePath = toolInput["file_path"] as? String,
      filePath.hasPrefix("/") else {
    debugLog("payload not parseable or no absolute file_path; allowing")
    exit(0)
}

guard ["Write", "Edit", "MultiEdit"].contains(toolName) else {
    debugLog("tool \(toolName) not reviewed; allowing")
    exit(0)
}

// MARK: - Compute old/new file contents

// Check the size before reading so a huge file isn't loaded just to skip it.
if let size = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.size] as? Int,
   size > maxReviewBytes {
    debugLog("file too large to review (\(size) bytes); allowing")
    exit(0)
}

let oldContent: String
if let data = FileManager.default.contents(atPath: filePath),
   let text = String(data: data, encoding: .utf8) {
    oldContent = text
} else {
    oldContent = ""
}

func applyEdit(to content: String, edit: [String: Any]) -> String? {
    guard let oldString = edit["old_string"] as? String,
          let newString = edit["new_string"] as? String else { return nil }
    let replaceAll = edit["replace_all"] as? Bool ?? false

    if oldString.isEmpty {
        // Empty old_string means "create file with new_string" semantics.
        return content.isEmpty ? newString : nil
    }
    guard content.contains(oldString) else { return nil }

    if replaceAll {
        return content.replacingOccurrences(of: oldString, with: newString)
    }
    guard let range = content.range(of: oldString) else { return nil }
    return content.replacingCharacters(in: range, with: newString)
}

let newContent: String
switch toolName {
case "Write":
    guard let content = toolInput["content"] as? String else { exit(0) }
    newContent = content
case "Edit":
    guard let result = applyEdit(to: oldContent, edit: toolInput) else { exit(0) }
    newContent = result
case "MultiEdit":
    guard let edits = toolInput["edits"] as? [[String: Any]] else { exit(0) }
    var working = oldContent
    for edit in edits {
        guard let next = applyEdit(to: working, edit: edit) else { exit(0) }
        working = next
    }
    newContent = working
default:
    exit(0)
}

guard newContent.utf8.count <= maxReviewBytes, newContent != oldContent else {
    debugLog("no effective change or file too large; allowing")
    exit(0)
}

// MARK: - Ask Sidekick for approval over the IPC socket

let socketPath = NSString(string: "~/.config/sidekick/sidekick.sock").expandingTildeInPath

func requestApproval() -> Bool? {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        debugLog("socket() failed: \(String(cString: strerror(errno)))")
        return nil
    }
    defer { close(socketFD) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
    guard socketPath.utf8CString.count <= maxPathLength else { return nil }
    socketPath.withCString { pathCString in
        withUnsafeMutablePointer(to: &addr.sun_path.0) { pathPtr in
            strncpy(pathPtr, pathCString, maxPathLength - 1)
            pathPtr[maxPathLength - 1] = 0
        }
    }

    let connected = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        debugLog("connect() failed: \(String(cString: strerror(errno)))")
        return nil
    }

    var command: [String: Any] = [
        "action": "show_diff",
        "path": filePath,
        "old": oldContent,
        "new": newContent
    ]
    // Scope "approve & remember" grants to the pane this hook ran in.
    if let paneID = ProcessInfo.processInfo.environment["SIDEKICK_PANE_ID"], !paneID.isEmpty {
        command["pane_id"] = paneID
    }
    guard var requestData = try? JSONSerialization.data(withJSONObject: command) else { return nil }
    guard requestData.count < maxRequestBytes else {
        debugLog("serialized request too large (\(requestData.count) bytes); allowing")
        return nil
    }
    requestData.append(UInt8(ascii: "\n"))

    let sent = requestData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
        guard var cursor = bytes.baseAddress else { return false }
        var remaining = requestData.count
        while remaining > 0 {
            let written = write(socketFD, cursor, remaining)
            guard written > 0 else { return false }
            remaining -= written
            cursor = cursor.advanced(by: written)
        }
        return true
    }
    guard sent else { return nil }
    shutdown(socketFD, SHUT_WR)

    // Block until the user decides; Sidekick holds the response open.
    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while responseData.count < 64 * 1024 {
        let bytesRead = read(socketFD, &buffer, buffer.count)
        if bytesRead <= 0 { break }
        responseData.append(contentsOf: buffer[0..<bytesRead])
        if buffer[0..<bytesRead].contains(UInt8(ascii: "\n")) { break }
    }

    guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
          response["ok"] as? Bool == true else {
        debugLog("bad/no response: \(String(data: responseData, encoding: .utf8) ?? "<binary>")")
        return nil
    }
    return response["accepted"] as? Bool
}

switch requestApproval() {
case .some(false):
    FileHandle.standardError.write(Data("User rejected this edit in Sidekick.\n".utf8))
    exit(2)
default:
    // Accepted, or Sidekick unavailable — allow the edit.
    exit(0)
}
