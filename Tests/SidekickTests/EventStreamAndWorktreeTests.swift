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

    // MARK: - WorktreeService teardown (real git)

    func testRemoveAndPruneWorktreeEndToEnd() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("sk-wt-\(UUID().uuidString)")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        var cleanup: [URL] = [repo]
        defer { cleanup.forEach { try? fm.removeItem(at: $0) } }

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
        }

        // Minimal repo with one commit so a branch can be created.
        try git(["init", "-q"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "Test"])
        try "hi".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "init"])

        let service = WorktreeService()
        let created = try service.ensureWorktree(forBranch: "feature/x", directory: repo.path)
        cleanup.append(URL(fileURLWithPath: created).deletingLastPathComponent())  // <repo>.worktrees
        XCTAssertTrue(fm.fileExists(atPath: created))

        let removed = try service.removeWorktree(forBranch: "feature/x", directory: repo.path)
        // git's porcelain reports the canonical path (/private/var vs /var on a
        // temp dir), so assert the suffix and that the checkout is actually gone
        // rather than comparing the full string.
        XCTAssertTrue(removed.hasSuffix(".worktrees/feature-x"))
        XCTAssertFalse(fm.fileExists(atPath: created))
        XCTAssertFalse(fm.fileExists(atPath: removed))

        // Idempotency: the branch no longer has a worktree.
        XCTAssertThrowsError(try service.removeWorktree(forBranch: "feature/x", directory: repo.path)) { error in
            XCTAssertEqual(error as? WorktreeService.WorktreeError, .noWorktreeForBranch("feature/x"))
        }

        // Prune is a no-op here but must still succeed.
        XCTAssertNoThrow(try service.pruneWorktrees(directory: repo.path))
    }
}
