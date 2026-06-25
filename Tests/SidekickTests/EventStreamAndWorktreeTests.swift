import XCTest
@testable import Sidekick

final class EventStreamAndWorktreeTests: XCTestCase {

    // MARK: - SidekickEvent JSON

    func testAgentStateEventEmitsSnakeCaseKeysAndOmitsNils() throws {
        var event = SidekickEvent(type: "agent_state")
        event.paneID = "pane-1"
        event.tabID = "tab-1"
        event.state = "working"

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "agent_state")
        XCTAssertEqual(object["pane_id"] as? String, "pane-1")
        XCTAssertEqual(object["tab_id"] as? String, "tab-1")
        XCTAssertEqual(object["state"] as? String, "working")
        XCTAssertNotNil(object["at"])
        // Command/diff-only fields stay out of an agent_state line.
        XCTAssertNil(object["exit_code"])
        XCTAssertNil(object["path"])
        XCTAssertNil(object["paneID"])
    }

    func testCommandEventCarriesExitCodeAndDuration() throws {
        var event = SidekickEvent(type: "command")
        event.paneID = "pane-1"
        event.command = "swift build"
        event.exitCode = 1
        event.duration = 12.5

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(object["command"] as? String, "swift build")
        XCTAssertEqual(object["exit_code"] as? Int, 1)
        XCTAssertEqual(object["duration"] as? Double, 12.5)
        XCTAssertNil(object["state"])
    }

    func testEventTimestampIsISO8601() throws {
        let event = SidekickEvent(type: "hello", at: Date(timeIntervalSince1970: 0))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        let at = try XCTUnwrap(object["at"] as? String)
        XCTAssertTrue(at.hasPrefix("1970-01-01T00:00:00"), "Unexpected timestamp: \(at)")
    }

    // MARK: - WorktreeService porcelain parsing

    func testWorktreePathFoundInPorcelain() {
        let porcelain = """
        worktree /repo
        HEAD abc123
        branch refs/heads/main

        worktree /repo.worktrees/feature-login
        HEAD def456
        branch refs/heads/feature/login
        """
        XCTAssertEqual(
            WorktreeService.worktreePath(forBranch: "feature/login", inPorcelain: porcelain),
            "/repo.worktrees/feature-login"
        )
        XCTAssertEqual(
            WorktreeService.worktreePath(forBranch: "main", inPorcelain: porcelain),
            "/repo"
        )
    }

    func testWorktreePathAbsentForUnknownBranch() {
        let porcelain = """
        worktree /repo
        HEAD abc123
        branch refs/heads/main
        """
        XCTAssertNil(WorktreeService.worktreePath(forBranch: "nope", inPorcelain: porcelain))
    }

    func testWorktreePathDoesNotMatchDetachedBareWorktree() {
        // A detached worktree has no `branch` line; it must not be mistaken for
        // the branch we're looking for.
        let porcelain = """
        worktree /repo
        HEAD abc123
        detached
        """
        XCTAssertNil(WorktreeService.worktreePath(forBranch: "main", inPorcelain: porcelain))
    }

    func testWorktreePathForBranchSanitizesSlashes() {
        let path = WorktreeService.worktreePath(forBranch: "feature/login", repoRoot: "/Users/x/myrepo")
        XCTAssertEqual(path, "/Users/x/myrepo.worktrees/feature-login")
    }
}
