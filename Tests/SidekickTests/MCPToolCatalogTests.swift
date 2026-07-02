import XCTest
@testable import Sidekick
import SidekickIPCCore
import SidekickMCPCore

/// Contract tests for the sidekick-mcp tool catalog. These are the guard the
/// review flagged as missing: "an MCP schema typo currently ships silently."
/// They pin the four un-typechecked string contracts — tool names, advertised
/// property names vs. what the handler reads, `required` arrays, and the
/// emitted IPC `action` — and cross-check the emitted commands against the
/// server's own `IPCCommandType.from` decoder so an action or enum drift fails
/// loudly here instead of at a live round-trip.
final class MCPToolCatalogTests: XCTestCase {
    // `ipc` is only touched by streaming tools' `execute` (wait_event), which
    // these tests never invoke, so a bare client with no live server is fine.
    private let tools = makeTools(ipc: SidekickIPCClient())

    private func tool(_ name: String) -> Tool {
        guard let t = tools.first(where: { $0.name == name }) else {
            fatalError("no tool named \(name)")
        }
        return t
    }

    /// The action each tool's buildRequest must emit. wait_event is excluded —
    /// it runs through `execute` and its action ("events") is handled by the
    /// server before `IPCCommandType.from`, not by it.
    private let expectedAction: [String: String] = [
        "sidekick_ping": "ping",
        "sidekick_pane_list": "pane_list",
        "sidekick_pane_current": "pane_current",
        "sidekick_new_tab": "new_tab",
        "sidekick_pane_split": "pane_split",
        "sidekick_pane_focus": "pane_focus",
        "sidekick_pane_close": "pane_close",
        "sidekick_pane_send_text": "pane_send_text",
        "sidekick_pane_run": "pane_run",
        "sidekick_pane_send_key": "pane_send_key",
        "sidekick_pane_read": "pane_read",
        "sidekick_wait_agent_status": "wait_agent_status",
        "sidekick_wait_output": "wait_output",
    ]

    /// Minimal valid arguments per tool that the server's decoder will accept.
    private func validArgs(for name: String) -> [String: Any] {
        let paneID = UUID().uuidString
        switch name {
        case "sidekick_ping", "sidekick_pane_list", "sidekick_new_tab":
            return [:]
        case "sidekick_pane_current", "sidekick_pane_focus", "sidekick_pane_close":
            return ["pane_id": paneID]
        case "sidekick_pane_split":
            return ["pane_id": paneID]
        case "sidekick_pane_send_text":
            return ["pane_id": paneID, "text": "hello"]
        case "sidekick_pane_run":
            return ["pane_id": paneID, "command": "ls -la"]
        case "sidekick_pane_send_key":
            return ["pane_id": paneID, "key": "enter"]
        case "sidekick_pane_read":
            return ["pane_id": paneID]
        case "sidekick_wait_agent_status":
            return ["pane_id": paneID, "status": "idle"]
        case "sidekick_wait_output":
            return ["pane_id": paneID, "match": "done"]
        default:
            return [:]
        }
    }

    private func decodeCommand(_ request: [String: Any]) throws -> IPCCommand {
        let data = try JSONSerialization.data(withJSONObject: request)
        return try JSONDecoder().decode(IPCCommand.self, from: data)
    }

    // MARK: - Catalog shape

    func testEveryToolNameIsUniqueAndWellFormed() {
        let names = tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate tool name would trap at startup")
        for name in names {
            XCTAssertNotNil(name.range(of: "^sidekick_[a-z_]+$", options: .regularExpression),
                            "\(name) doesn't match the sidekick_ naming convention")
        }
    }

    func testEveryInputSchemaIsAnObjectWithRequiredSubsetOfProperties() {
        for tool in tools {
            let schema = tool.inputSchema
            XCTAssertEqual(schema["type"] as? String, "object", "\(tool.name) schema type")
            let properties = (schema["properties"] as? [String: Any]) ?? [:]
            let required = (schema["required"] as? [String]) ?? []
            for key in required {
                XCTAssertNotNil(properties[key],
                                "\(tool.name): required field '\(key)' has no matching property in the schema")
            }
        }
    }

    // MARK: - Advertised properties vs. handler reads

    func testValidArgsFromSchemaBuildTheExpectedAction() throws {
        for (name, action) in expectedAction {
            let request = try tool(name).buildRequest(validArgs(for: name))
            XCTAssertEqual(request["action"] as? String, action, "\(name) emitted the wrong action")
        }
    }

    func testRequiredFieldsAreEnforcedByBuildRequest() {
        // Omitting any advertised-required field must throw — catches a `required`
        // array that names a field the handler doesn't actually demand (and vice
        // versa, since the handler's requireString call is what throws here).
        for (name, _) in expectedAction {
            let schema = tool(name).inputSchema
            let required = (schema["required"] as? [String]) ?? []
            for missing in required {
                var args = validArgs(for: name)
                args.removeValue(forKey: missing)
                XCTAssertThrowsError(try tool(name).buildRequest(args),
                                     "\(name): omitting required '\(missing)' should throw") { error in
                    XCTAssertTrue(error is ToolError, "expected ToolError, got \(error)")
                }
            }
        }
    }

    // MARK: - Emitted action decodes to a valid server command

    func testEveryEmittedActionDecodesToAKnownCommand() throws {
        // The core "silent typo" guard: a mistyped action like "pane_slit" would
        // compile and list fine but be rejected only at a live round-trip.
        for (name, _) in expectedAction {
            let request = try tool(name).buildRequest(validArgs(for: name))
            let command = try decodeCommand(request)
            XCTAssertNotNil(IPCCommandType.from(command),
                            "\(name)'s emitted command was rejected by IPCCommandType.from")
        }
    }

    // MARK: - Enum values match the server's accepted set

    func testWaitAgentStatusEnumMatchesAgentStateCases() {
        let schema = tool("sidekick_wait_agent_status").inputSchema
        let properties = schema["properties"] as? [String: Any]
        let statusProp = properties?["status"] as? [String: Any]
        let advertised = Set((statusProp?["enum"] as? [String]) ?? [])
        let serverAccepted = Set(AgentState.allCases.map(\.rawValue))
        XCTAssertEqual(advertised, serverAccepted,
                       "wait_agent_status status enum drifted from AgentState")
    }

    func testPaneSplitDirectionEnumValuesAreAllAccepted() throws {
        let schema = tool("sidekick_pane_split").inputSchema
        let properties = schema["properties"] as? [String: Any]
        let directionProp = properties?["direction"] as? [String: Any]
        let directions = (directionProp?["enum"] as? [String]) ?? []
        XCTAssertFalse(directions.isEmpty)
        for direction in directions {
            let request = try tool("sidekick_pane_split").buildRequest(["pane_id": UUID().uuidString, "direction": direction])
            let command = try decodeCommand(request)
            guard case .paneSplit = IPCCommandType.from(command) else {
                return XCTFail("direction '\(direction)' was not accepted as a pane_split")
            }
        }
    }

    func testPaneReadSourceEnumValuesAreAllAccepted() throws {
        let schema = tool("sidekick_pane_read").inputSchema
        let properties = schema["properties"] as? [String: Any]
        let sourceProp = properties?["source"] as? [String: Any]
        let sources = (sourceProp?["enum"] as? [String]) ?? []
        XCTAssertEqual(Set(sources), ["visible", "recent"])
        for source in sources {
            let request = try tool("sidekick_pane_read").buildRequest(["pane_id": UUID().uuidString, "source": source])
            let command = try decodeCommand(request)
            guard case .paneRead = IPCCommandType.from(command) else {
                return XCTFail("source '\(source)' was not accepted as a pane_read")
            }
        }
    }

    // MARK: - Intentional arg→IPC renames stay pinned

    func testPaneRunMapsCommandToTextWithoutTrailingReturn() throws {
        let request = try tool("sidekick_pane_run").buildRequest(["pane_id": UUID().uuidString, "command": "make test"])
        XCTAssertEqual(request["action"] as? String, "pane_run")
        XCTAssertEqual(request["text"] as? String, "make test",
                       "pane_run must not embed a carriage return: TUIs treat one delivered in the "
                       + "same chunk as pasted text, so the server sends Enter as a separate write")
    }

    func testPaneReadJSONFlagMapsToFormatJSON() throws {
        let withJSON = try tool("sidekick_pane_read").buildRequest(["pane_id": UUID().uuidString, "json": true])
        XCTAssertEqual(withJSON["format"] as? String, "json")
        let withoutJSON = try tool("sidekick_pane_read").buildRequest(["pane_id": UUID().uuidString])
        XCTAssertNil(withoutJSON["format"], "format should be absent (server defaults to text) when json isn't set")
    }

    // MARK: - wait_event

    func testWaitEventRunsThroughExecuteNotBuildRequest() {
        let waitEvent = tool("sidekick_wait_event")
        XCTAssertNotNil(waitEvent.execute, "wait_event must have an execute closure")
        XCTAssertThrowsError(try waitEvent.buildRequest([:]),
                             "wait_event's buildRequest is a guard rail and must throw")
    }
}
