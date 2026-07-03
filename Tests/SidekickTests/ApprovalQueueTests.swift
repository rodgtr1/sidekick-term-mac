import XCTest
import AppKit
@testable import Sidekick

@MainActor
private final class StubApprovalHost: DiffApprovalHost {
    var shouldAutoApproveEdits = false
    var approvalConfig = ApprovalConfig()
    var automationWindow: NSWindow?
    var paneWorkingDirectories: [UUID?: String] = [:]
    func workingDirectory(forPane paneID: UUID?) -> String? { paneWorkingDirectories[paneID] }
}

@MainActor
final class ApprovalQueueTests: XCTestCase {
    func testResolveRunsCompletionOnceAndRemovesEntry() {
        let queue = ApprovalQueue()
        var outcomes: [ApprovalOutcome] = []
        queue.enqueue(paneID: nil, path: "/tmp/a.txt", old: "", new: "x") { outcomes.append($0) }

        XCTAssertEqual(queue.pending.count, 1)
        let id = queue.pending[0].id

        queue.resolve(id: id, outcome: ApprovalOutcome(accepted: true, remember: .none))
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].accepted)

        // A second resolve for the same id (click racing a drain) is a no-op.
        queue.resolve(id: id, outcome: .rejected)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testDrainAllDecidesPerEntryAndEmptiesQueue() {
        let queue = ApprovalQueue()
        var results: [String: Bool] = [:]
        queue.enqueue(paneID: nil, path: "/tmp/open.txt", old: "", new: "x") { results["open"] = $0.accepted }
        queue.enqueue(paneID: nil, path: "/tmp/closed.env", old: "", new: "x") { results["closed"] = $0.accepted }

        queue.drainAll { entry in
            ApprovalOutcome(accepted: !entry.path.hasSuffix(".env"), remember: .none)
        }

        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(results["open"], true)
        XCTAssertEqual(results["closed"], false)
    }

    func testCountForPaneOnlyCountsThatPane() {
        let queue = ApprovalQueue()
        let paneA = UUID(), paneB = UUID()
        queue.enqueue(paneID: paneA, path: "/tmp/a.txt", old: "", new: "x") { _ in }
        queue.enqueue(paneID: paneA, path: "/tmp/b.txt", old: "", new: "x") { _ in }
        queue.enqueue(paneID: paneB, path: "/tmp/c.txt", old: "", new: "x") { _ in }

        XCTAssertEqual(queue.count(forPane: paneA), 2)
        XCTAssertEqual(queue.count(forPane: paneB), 1)
        XCTAssertEqual(queue.count(forPane: nil), 0)
    }

    func testEnqueueAndResolvePostChangeNotifications() {
        let queue = ApprovalQueue()
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: .pendingApprovalsChanged, object: queue, queue: nil
        ) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        queue.enqueue(paneID: nil, path: "/tmp/a.txt", old: "", new: "x") { _ in }
        XCTAssertEqual(counter.value, 1)
        queue.resolve(id: queue.pending[0].id, outcome: .rejected)
        XCTAssertEqual(counter.value, 2)
    }
}

@MainActor
final class DiffApprovalCoordinatorQueueTests: XCTestCase {
    private func makeCoordinator(
        host: StubApprovalHost,
        queue: ApprovalQueue
    ) -> (DiffApprovalCoordinator, events: () -> [String]) {
        final class Events { var lines: [String] = [] }
        let events = Events()
        let coordinator = DiffApprovalCoordinator(host: host, queue: queue) { path, decision in
            events.lines.append("\(decision):\((path as NSString).lastPathComponent)")
        }
        return (coordinator, { events.lines })
    }

    func testAutoApproveBypassesQueue() {
        let host = StubApprovalHost()
        host.shouldAutoApproveEdits = true
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, events) = makeCoordinator(host: host, queue: queue)

        var accepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/auto.txt", old: "", new: "x") { accepted = $0 }

        XCTAssertEqual(accepted, true)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(events(), ["accepted:auto.txt"])
    }

    func testAskModeParksInQueueUntilResolved() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, events) = makeCoordinator(host: host, queue: queue)

        var accepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/ask.txt", old: "", new: "x") { accepted = $0 }

        XCTAssertNil(accepted)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertEqual(events(), ["pending:ask.txt"])

        queue.resolve(id: queue.pending[0].id, outcome: ApprovalOutcome(accepted: true, remember: .none))
        XCTAssertEqual(accepted, true)
        XCTAssertEqual(events(), ["pending:ask.txt", "accepted:ask.txt"])
    }

    func testNoWindowFailsOpenExceptAlwaysAsk() {
        let host = StubApprovalHost()
        host.automationWindow = nil
        host.approvalConfig.alwaysAsk = [".env"]
        let queue = ApprovalQueue()
        let (coordinator, _) = makeCoordinator(host: host, queue: queue)

        var plainAccepted: Bool?
        var secretAccepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/plain.txt", old: "", new: "x") { plainAccepted = $0 }
        coordinator.requestApproval(paneID: nil, path: "/tmp/.env", old: "", new: "x") { secretAccepted = $0 }

        XCTAssertEqual(plainAccepted, true)
        XCTAssertEqual(secretAccepted, false)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testWindowCloseDrainFailsOpenExceptAlwaysAsk() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        host.approvalConfig.alwaysAsk = [".env"]
        let queue = ApprovalQueue()
        let (coordinator, _) = makeCoordinator(host: host, queue: queue)

        var plainAccepted: Bool?
        var secretAccepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/plain.txt", old: "", new: "x") { plainAccepted = $0 }
        coordinator.requestApproval(paneID: nil, path: "/tmp/.env", old: "", new: "x") { secretAccepted = $0 }
        XCTAssertEqual(queue.pending.count, 2)

        coordinator.prepareForWindowClose()
        XCTAssertEqual(plainAccepted, true)
        XCTAssertEqual(secretAccepted, false)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testRememberGrantAutoResolvesQueuedEditsItCovers() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, _) = makeCoordinator(host: host, queue: queue)
        let pane = UUID(), otherPane = UUID()

        var firstAccepted: Bool?
        var siblingAccepted: Bool?
        var otherPaneAccepted: Bool?
        coordinator.requestApproval(paneID: pane, path: "/tmp/proj/a.txt", old: "", new: "x") { firstAccepted = $0 }
        coordinator.requestApproval(paneID: pane, path: "/tmp/proj/b.txt", old: "", new: "x") { siblingAccepted = $0 }
        coordinator.requestApproval(paneID: otherPane, path: "/tmp/proj/c.txt", old: "", new: "x") { otherPaneAccepted = $0 }
        XCTAssertEqual(queue.pending.count, 3)

        // Approving the first with a folder grant should clear the same-pane
        // sibling in the same folder, but grants are per-pane: the other
        // pane's request keeps waiting.
        queue.resolve(id: queue.pending[0].id, outcome: ApprovalOutcome(accepted: true, remember: .folder))

        XCTAssertEqual(firstAccepted, true)
        XCTAssertEqual(siblingAccepted, true)
        XCTAssertNil(otherPaneAccepted)
        XCTAssertEqual(queue.pending.count, 1)
    }
}
