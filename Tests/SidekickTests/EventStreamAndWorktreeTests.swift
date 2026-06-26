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

    func testTelemetryEventEncodesSnakeCaseAndOmitsNils() throws {
        var event = SidekickEvent(type: "telemetry")
        event.paneID = "p1"
        event.model = "claude-opus-4-8"
        event.inputTokens = 1000
        event.outputTokens = 500
        event.costUSD = 0.36
        event.turns = 7
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "telemetry")
        XCTAssertEqual(object["pane_id"] as? String, "p1")
        XCTAssertEqual(object["model"] as? String, "claude-opus-4-8")
        XCTAssertEqual(object["input_tokens"] as? Int, 1000)
        XCTAssertEqual(object["output_tokens"] as? Int, 500)
        XCTAssertEqual(object["cost_usd"] as? Double, 0.36)
        XCTAssertEqual(object["turns"] as? Int, 7)
        // Unrelated event fields stay omitted.
        XCTAssertNil(object["state"])
        XCTAssertNil(object["command"])
        XCTAssertNil(object["decision"])
    }

    // MARK: - Event filtering & backlog snapshot

    private func event(_ type: String, pane: String? = nil, state: String? = nil) -> SidekickEvent {
        var e = SidekickEvent(type: type)
        e.paneID = pane
        e.state = state
        return e
    }

    func testEventFilterNilMatchesEverything() {
        XCTAssertTrue(EventFilter().matches(event("agent_state", pane: "A")))
        XCTAssertTrue(EventFilter().matches(event("command", pane: "B")))
    }

    func testEventFilterAlwaysDeliversHello() {
        // A late subscriber must still learn it connected, even under a filter
        // that would otherwise exclude the hello marker (no pane, no type).
        XCTAssertTrue(EventFilter(paneID: "A", type: "command").matches(event("hello")))
    }

    func testEventFilterByPaneAndType() {
        let paneA = EventFilter(paneID: "A", type: nil)
        XCTAssertTrue(paneA.matches(event("agent_state", pane: "A")))
        XCTAssertFalse(paneA.matches(event("agent_state", pane: "B")))

        let onlyCommand = EventFilter(paneID: nil, type: "command")
        XCTAssertTrue(onlyCommand.matches(event("command", pane: "A")))
        XCTAssertFalse(onlyCommand.matches(event("agent_state", pane: "A")))

        let both = EventFilter(paneID: "A", type: "agent_state")
        XCTAssertTrue(both.matches(event("agent_state", pane: "A")))
        XCTAssertFalse(both.matches(event("agent_state", pane: "B")))
        XCTAssertFalse(both.matches(event("command", pane: "A")))
    }

    func testSnapshotKeepsLatestAgentStatePerPane() {
        let broadcaster = EventBroadcaster()
        broadcaster.emit(event("agent_state", pane: "B", state: "working"))
        broadcaster.emit(event("agent_state", pane: "A", state: "working"))
        broadcaster.emit(event("agent_state", pane: "A", state: "ready"))   // latest for A
        broadcaster.emit(event("command", pane: "A"))                        // not state — excluded

        let snapshot = broadcaster.currentStateSnapshot()
        XCTAssertEqual(snapshot.map(\.paneID), ["A", "B"])  // ordered by pane id
        XCTAssertEqual(snapshot.first { $0.paneID == "A" }?.state, "ready")
        XCTAssertEqual(snapshot.first { $0.paneID == "B" }?.state, "working")
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

    // MARK: - parseWorktrees (full porcelain records)

    func testParseWorktreesReturnsEveryRecordInOrder() {
        let porcelain = """
        worktree /repo
        HEAD abc123
        branch refs/heads/main

        worktree /repo.worktrees/feature-login
        HEAD def456
        branch refs/heads/feature/login

        """
        let worktrees = WorktreeService.parseWorktrees(porcelain: porcelain)
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0], GitWorktree(path: "/repo", branch: "main", head: "abc123",
                                                 isDetached: false, isLocked: false, isBare: false))
        XCTAssertEqual(worktrees[1].path, "/repo.worktrees/feature-login")
        XCTAssertEqual(worktrees[1].branch, "feature/login")   // refs/heads/ stripped
    }

    func testParseWorktreesFlagsDetachedLockedAndBare() {
        let porcelain = """
        worktree /repo
        bare

        worktree /repo.worktrees/detached
        HEAD aaa111
        detached

        worktree /repo.worktrees/pinned
        HEAD bbb222
        branch refs/heads/pinned
        locked under review
        """
        let worktrees = WorktreeService.parseWorktrees(porcelain: porcelain)
        XCTAssertEqual(worktrees.count, 3)

        XCTAssertTrue(worktrees[0].isBare)
        XCTAssertNil(worktrees[0].branch)

        XCTAssertTrue(worktrees[1].isDetached)
        XCTAssertNil(worktrees[1].branch)

        XCTAssertTrue(worktrees[2].isLocked)   // `locked <reason>` still flags locked
        XCTAssertEqual(worktrees[2].branch, "pinned")
    }

    func testParseWorktreesHandlesTrailingRecordWithoutBlankLine() {
        // git's final record isn't followed by a blank line; it must still emit.
        let porcelain = """
        worktree /repo
        HEAD abc123
        branch refs/heads/main
        """
        let worktrees = WorktreeService.parseWorktrees(porcelain: porcelain)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees[0].branch, "main")
    }

    func testParseWorktreesEmptyOutputIsEmpty() {
        XCTAssertTrue(WorktreeService.parseWorktrees(porcelain: "").isEmpty)
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
