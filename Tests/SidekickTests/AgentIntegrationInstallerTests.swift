import XCTest
@testable import Sidekick

final class AgentIntegrationInstallerTests: XCTestCase {

    // MARK: - Claude hook merging

    private func hookCommands(_ hooks: [String: Any], event: String) -> [String] {
        (hooks[event] as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testAddClaudeHookToEmptyConfig() {
        var hooks: [String: Any] = [:]
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/sidekick-agent-status done")

        XCTAssertEqual(hookCommands(hooks, event: "Stop"), ["/a/sidekick-agent-status done"])
    }

    func testAddClaudeHookSkipsExactDuplicate() {
        var hooks: [String: Any] = [:]
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/sidekick-agent-status done")
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/sidekick-agent-status done")

        XCTAssertEqual(hookCommands(hooks, event: "Stop").count, 1)
    }

    func testAddClaudeHookSkipsSamePayloadAtDifferentPath() {
        // A from-source install at ~/.local/bin must satisfy the bundle
        // installer, not get duplicated.
        var hooks: [String: Any] = [
            "Stop": [["hooks": [["type": "command", "command": "/Users/x/.local/bin/sidekick-agent-status done"]]]]
        ]
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks,
            event: "Stop",
            command: "/Applications/Sidekick.app/Contents/MacOS/sidekick-agent-status done"
        )

        XCTAssertEqual(hookCommands(hooks, event: "Stop").count, 1)
    }

    func testAddClaudeHookPreservesForeignHooksAndAddsMatcher() {
        var hooks: [String: Any] = [
            "PreToolUse": [["hooks": [["type": "command", "command": "/usr/local/bin/some-other-hook"]]]]
        ]
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks,
            event: "PreToolUse",
            command: "/a/sidekick-hook",
            matcher: "Write|Edit|MultiEdit"
        )

        let groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[1]["matcher"] as? String, "Write|Edit|MultiEdit")
        XCTAssertEqual(hookCommands(hooks, event: "PreToolUse").first, "/usr/local/bin/some-other-hook")
    }

    // MARK: - Codex TOML features section

    func testCodexHooksEnabledAddedToEmptyConfig() {
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: "")
        XCTAssertTrue(result.contains("[features]"))
        XCTAssertTrue(result.contains("hooks = true"))
    }

    func testCodexFeaturesInsertedBeforeFirstTableToKeepTopLevelKeys() {
        let config = """
        model = "gpt-5.5"

        [projects."/Users/x"]
        trust_level = "trusted"
        """
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: config)

        let featuresRange = result.range(of: "[features]")
        let projectsRange = result.range(of: "[projects.")
        XCTAssertNotNil(featuresRange)
        XCTAssertNotNil(projectsRange)
        XCTAssertLessThan(featuresRange!.lowerBound, projectsRange!.lowerBound)
        // Top-level key must still come before any table header.
        XCTAssertLessThan(result.range(of: "model = ")!.lowerBound, featuresRange!.lowerBound)
    }

    func testCodexExistingFeaturesSectionGainsHooksKey() {
        let config = """
        [features]
        something = 1

        [other]
        key = 2
        """
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: config)

        XCTAssertTrue(result.contains("hooks = true"))
        // Inserted inside [features], not into [other].
        let hooksRange = result.range(of: "hooks = true")!
        let otherRange = result.range(of: "[other]")!
        XCTAssertLessThan(hooksRange.lowerBound, otherRange.lowerBound)
    }

    func testCodexHooksFalseFlippedToTrue() {
        let config = """
        [features]
        hooks = false
        """
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: config)

        XCTAssertTrue(result.contains("hooks = true"))
        XCTAssertFalse(result.contains("hooks = false"))
    }
}
