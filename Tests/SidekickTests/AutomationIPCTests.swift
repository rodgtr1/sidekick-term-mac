import XCTest
@testable import Sidekick

final class AutomationIPCTests: XCTestCase {
    func testPaneSplitCommandDecodesStructuredArguments() throws {
        let paneID = UUID()
        let json = """
        {
          "action": "pane_split",
          "pane_id": "\(paneID.uuidString)",
          "direction": "down",
          "cwd": "/tmp",
          "focus": false,
          "command": ["claude", "-p", "review tests"]
        }
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))

        guard case let .paneSplit(decodedID, direction, cwd, argv, focus) = IPCCommandType.from(command) else {
            return XCTFail("Expected paneSplit")
        }
        XCTAssertEqual(decodedID, paneID)
        if case .vertical = direction {} else { XCTFail("Expected vertical split") }
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(argv ?? [], ["claude", "-p", "review tests"])
        XCTAssertFalse(focus)
    }

    func testPaneReadRejectsUnboundedLineCount() throws {
        let json = """
        {"action":"pane_read","pane_id":"\(UUID().uuidString)","lines":10001}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        XCTAssertNil(IPCCommandType.from(command))
    }

    func testTabAgentStateAggregatesMostUrgentPane() {
        let tab = TabModel()
        let second = PaneModel()
        tab.panes.append(second)

        tab.panes[0].agentState = .done
        second.agentState = .working
        tab.updateAgentStateFromPanes()
        XCTAssertEqual(tab.agentState, .working)

        tab.panes[0].agentState = .ready
        tab.updateAgentStateFromPanes()
        XCTAssertEqual(tab.agentState, .ready)
    }

    func testPaneInfoUsesSnakeCaseJSONKeys() throws {
        let info = IPCPaneInfo(
            paneID: "pane",
            tabID: "tab",
            type: "terminal",
            cwd: "/tmp",
            focused: true,
            agentStatus: "working",
            processID: 42
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any]
        )
        XCTAssertEqual(object["pane_id"] as? String, "pane")
        XCTAssertEqual(object["agent_status"] as? String, "working")
        XCTAssertEqual(object["process_id"] as? Int, 42)
    }
}
