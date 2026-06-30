import Foundation
import SidekickIPCCore

/// sidekick-mcp — a Model Context Protocol server that exposes Sidekick's
/// pane-orchestration verbs as MCP tools.
///
/// It speaks MCP over stdio (newline-delimited JSON-RPC 2.0) and translates
/// `tools/call` invocations into the same Unix-socket IPC commands that
/// `sidekick-ctl` already uses. Any MCP client (Claude Desktop, Claude Code,
/// Cursor, …) can then drive Sidekick natively — no `sidekick-ctl` shell-outs
/// and no SKILL.md required.
///
/// Register it with an MCP client by pointing the client at this binary, e.g.
/// in a `.mcp.json`:
///   { "mcpServers": { "sidekick": { "command": "/path/to/sidekick-mcp" } } }

// MARK: - Logging (stderr only — stdout is the protocol channel)

func logLine(_ message: String) {
    FileHandle.standardError.write(Data("sidekick-mcp: \(message)\n".utf8))
}

// MARK: - IPC client (talks to the running Sidekick over its Unix socket)

private let ipc = SidekickIPCClient()

// MARK: - Tool catalog

/// One MCP tool, plus how to turn its arguments into an IPC request and how to
/// render the IPC reply as human/agent-readable text.
private struct Tool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// Builds the IPC request, or throws a message describing the bad arguments.
    let buildRequest: (_ arguments: [String: Any]) throws -> [String: Any]
    /// Renders a successful IPC reply's `result` (may be nil) into tool text.
    let render: (_ result: [String: Any]?) -> String
}

private struct ToolError: Error { let message: String }

private func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = arguments[key] as? String, !value.isEmpty else {
        throw ToolError(message: "Missing required string argument: \(key)")
    }
    return value
}

private func prettyJSON(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "\(value)" }
    return string
}

private func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
    var schema: [String: Any] = ["type": "object", "properties": properties]
    if !required.isEmpty { schema["required"] = required }
    return schema
}

private let paneIDProperty: [String: Any] = ["type": "string", "description": "Opaque pane ID from pane_list / pane_current / pane_split."]

private let tools: [Tool] = [
    Tool(
        name: "sidekick_ping",
        description: "Check whether Sidekick is running and reachable.",
        inputSchema: object([:]),
        buildRequest: { _ in ["action": "ping"] },
        render: { _ in "Sidekick is running." }
    ),
    Tool(
        name: "sidekick_pane_list",
        description: "List every terminal pane across all tabs, with cwd, focus, and agent status. Start here to discover pane IDs.",
        inputSchema: object([:]),
        buildRequest: { _ in ["action": "pane_list"] },
        render: { result in prettyJSON(result?["panes"] ?? []) }
    ),
    Tool(
        name: "sidekick_pane_current",
        description: "Get the focused pane, or a specific pane when pane_id is given.",
        inputSchema: object(["pane_id": paneIDProperty]),
        buildRequest: { args in
            var request: [String: Any] = ["action": "pane_current"]
            if let paneID = args["pane_id"] as? String { request["pane_id"] = paneID }
            return request
        },
        render: { result in prettyJSON(result?["pane"] ?? [:]) }
    ),
    Tool(
        name: "sidekick_new_tab",
        description: "Open a new terminal tab, optionally in a given working directory.",
        inputSchema: object(["cwd": ["type": "string", "description": "Absolute directory to start in."]]),
        buildRequest: { args in
            var request: [String: Any] = ["action": "new_tab"]
            request["cwd"] = (args["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
            return request
        },
        render: { _ in "Opened a new tab." }
    ),
    Tool(
        name: "sidekick_pane_split",
        description: "Split a pane to create a new terminal beside it. Use --no-focus semantics by passing focus=false to avoid stealing the user's focus. Pass command to launch a worker (e.g. [\"claude\"]).",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "direction": ["type": "string", "enum": ["right", "down"], "description": "Split direction. Defaults to right."],
            "cwd": ["type": "string", "description": "Absolute directory for the new pane."],
            "command": ["type": "array", "items": ["type": "string"], "description": "argv to launch in the new pane (e.g. [\"claude\", \"-p\", \"review tests\"])."],
            "focus": ["type": "boolean", "description": "Whether to focus the new pane. Defaults to true."],
            "worktree": ["type": "string", "description": "Branch name. Creates (or reuses) a git worktree for it from the source pane's repo and opens the new pane there — safe fan-out for parallel agents. Overrides cwd."]
        ], required: ["pane_id"]),
        buildRequest: { args in
            var request: [String: Any] = [
                "action": "pane_split",
                "pane_id": try requireString(args, "pane_id"),
                "direction": (args["direction"] as? String) ?? "right",
                "focus": (args["focus"] as? Bool) ?? true
            ]
            if let cwd = args["cwd"] as? String { request["cwd"] = cwd }
            if let command = args["command"] as? [String], !command.isEmpty { request["command"] = command }
            if let worktree = args["worktree"] as? String { request["worktree"] = worktree }
            return request
        },
        render: { result in prettyJSON(result?["pane"] ?? [:]) }
    ),
    Tool(
        name: "sidekick_pane_focus",
        description: "Bring a pane to the foreground and focus it.",
        inputSchema: object(["pane_id": paneIDProperty], required: ["pane_id"]),
        buildRequest: { args in ["action": "pane_focus", "pane_id": try requireString(args, "pane_id")] },
        render: { result in prettyJSON(result?["pane"] ?? [:]) }
    ),
    Tool(
        name: "sidekick_pane_close",
        description: "Close a pane. Do not close panes you did not create unless explicitly asked.",
        inputSchema: object(["pane_id": paneIDProperty], required: ["pane_id"]),
        buildRequest: { args in ["action": "pane_close", "pane_id": try requireString(args, "pane_id")] },
        render: { _ in "Closed the pane." }
    ),
    Tool(
        name: "sidekick_pane_send_text",
        description: "Type text into a pane without pressing Enter.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "text": ["type": "string", "description": "Literal text to type."]
        ], required: ["pane_id", "text"]),
        buildRequest: { args in
            ["action": "pane_send_text", "pane_id": try requireString(args, "pane_id"), "text": try requireString(args, "text")]
        },
        render: { _ in "Sent text." }
    ),
    Tool(
        name: "sidekick_pane_run",
        description: "Type a command into a pane and press Enter to run it.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "command": ["type": "string", "description": "Command line to run."]
        ], required: ["pane_id", "command"]),
        buildRequest: { args in
            ["action": "pane_send_text", "pane_id": try requireString(args, "pane_id"), "text": try requireString(args, "command") + "\r"]
        },
        render: { _ in "Ran the command." }
    ),
    Tool(
        name: "sidekick_pane_send_key",
        description: "Send a named key to a pane. Supported: enter, tab, esc, backspace, ctrl-c, ctrl-d, up, down, left, right.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "key": ["type": "string", "description": "Named key, e.g. enter, ctrl-c, esc."]
        ], required: ["pane_id", "key"]),
        buildRequest: { args in
            ["action": "pane_send_key", "pane_id": try requireString(args, "pane_id"), "key": try requireString(args, "key")]
        },
        render: { _ in "Sent key." }
    ),
    Tool(
        name: "sidekick_pane_read",
        description: "Read a pane's output. source=visible (the screen) or recent (scrollback). Set json=true for structured per-command records {command, exit_code, duration, output} built from shell-integration marks — easier to reason over than raw text.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "source": ["type": "string", "enum": ["visible", "recent"], "description": "visible (default) or recent."],
            "lines": ["type": "integer", "description": "Limit to the last N lines (text) or N command records (json)."],
            "json": ["type": "boolean", "description": "Return structured command records instead of raw text."]
        ], required: ["pane_id"]),
        buildRequest: { args in
            var request: [String: Any] = [
                "action": "pane_read",
                "pane_id": try requireString(args, "pane_id"),
                "source": (args["source"] as? String) ?? "visible"
            ]
            if let lines = args["lines"] as? Int { request["lines"] = lines }
            if (args["json"] as? Bool) == true { request["format"] = "json" }
            return request
        },
        render: { result in
            if let commands = result?["commands"] { return prettyJSON(commands) }
            return (result?["text"] as? String) ?? ""
        }
    ),
    Tool(
        name: "sidekick_wait_agent_status",
        description: "Block until a pane's agent reaches a status (idle|working|ready|done) or the timeout elapses. After it returns, read the pane rather than assuming success.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "status": ["type": "string", "enum": ["idle", "working", "ready", "done"], "description": "Target agent status."],
            "timeout_ms": ["type": "integer", "description": "Timeout in milliseconds (default 30000)."]
        ], required: ["pane_id", "status"]),
        buildRequest: { args in
            [
                "action": "wait_agent_status",
                "pane_id": try requireString(args, "pane_id"),
                "status": try requireString(args, "status"),
                "timeout_ms": (args["timeout_ms"] as? Int) ?? 30_000
            ]
        },
        render: { result in
            ((result?["matched"] as? Bool) == true) ? "Reached the requested agent status." : "Timed out before reaching the requested agent status."
        }
    ),
    Tool(
        name: "sidekick_wait_output",
        description: "Block until a pane's output contains a substring or the timeout elapses. After it returns, read the pane to see context.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "match": ["type": "string", "description": "Substring to wait for."],
            "timeout_ms": ["type": "integer", "description": "Timeout in milliseconds (default 30000)."]
        ], required: ["pane_id", "match"]),
        buildRequest: { args in
            [
                "action": "wait_output",
                "pane_id": try requireString(args, "pane_id"),
                "match": try requireString(args, "match"),
                "timeout_ms": (args["timeout_ms"] as? Int) ?? 30_000
            ]
        },
        render: { result in
            ((result?["matched"] as? Bool) == true) ? "Matched the requested output." : "Timed out before the output appeared."
        }
    )
]

private let toolsByName: [String: Tool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

// MARK: - JSON-RPC plumbing over stdio

/// Writes one newline-delimited JSON-RPC message to stdout.
private func emit(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(UInt8(ascii: "\n"))
    FileHandle.standardOutput.write(data)
}

private func respond(id: Any, result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

private func respondError(id: Any, code: Int, message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

/// Wraps text in the MCP tool-result content shape.
private func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
}

private let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

private func handleInitialize(id: Any, params: [String: Any]) {
    // Echo the client's protocol version when we support it; otherwise offer ours.
    let requested = params["protocolVersion"] as? String
    let agreed = (requested.map(supportedProtocolVersions.contains) ?? false) ? requested! : "2025-06-18"
    respond(id: id, result: [
        "protocolVersion": agreed,
        "capabilities": ["tools": [:]],
        "serverInfo": ["name": "sidekick", "version": "1.0.0"],
        "instructions": "Control Sidekick terminal panes and orchestrate visible worker agents. Call sidekick_pane_list first to discover pane IDs."
    ])
}

@MainActor
private func handleToolsList(id: Any) {
    let listed = tools.map { tool in
        ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema] as [String: Any]
    }
    respond(id: id, result: ["tools": listed])
}

@MainActor
private func handleToolsCall(id: Any, params: [String: Any]) {
    guard let name = params["name"] as? String, let tool = toolsByName[name] else {
        respondError(id: id, code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "<none>")")
        return
    }
    let arguments = (params["arguments"] as? [String: Any]) ?? [:]

    let request: [String: Any]
    do {
        request = try tool.buildRequest(arguments)
    } catch let error as ToolError {
        respond(id: id, result: toolResult(error.message, isError: true))
        return
    } catch {
        respond(id: id, result: toolResult("Invalid arguments: \(error)", isError: true))
        return
    }

    guard let reply = ipc.send(request) else {
        respond(id: id, result: toolResult("Sidekick is not responding. Is the app running?", isError: true))
        return
    }
    guard reply["ok"] as? Bool == true else {
        let message = reply["error"] as? String ?? "Sidekick rejected the request."
        respond(id: id, result: toolResult(message, isError: true))
        return
    }
    respond(id: id, result: toolResult(tool.render(reply["result"] as? [String: Any])))
}

// MARK: - Main loop

logLine("ready on \(defaultSidekickSocketPath())")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        continue
    }

    let method = message["method"] as? String
    let id = message["id"]   // absent for notifications
    let params = (message["params"] as? [String: Any]) ?? [:]

    switch method {
    case "initialize":
        if let id { handleInitialize(id: id, params: params) }
    case "notifications/initialized", "notifications/cancelled":
        break   // notifications: no response
    case "ping":
        if let id { respond(id: id, result: [:]) }
    case "tools/list":
        if let id { handleToolsList(id: id) }
    case "tools/call":
        if let id { handleToolsCall(id: id, params: params) }
    default:
        if let id { respondError(id: id, code: -32601, message: "Method not found: \(method ?? "<none>")") }
    }
}
