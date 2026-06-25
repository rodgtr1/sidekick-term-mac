import Foundation
import Darwin

/// One line in the `sidekick-ctl events --follow` JSONL stream. A single struct
/// with optional fields (matching `IPCResult`'s house style) keeps the wire
/// format flat and self-describing; the synthesized encoder omits nil fields, so
/// each event only carries the keys its `type` populates.
///
///  - `hello`        — sent once on subscribe, so a client knows it's connected.
///  - `agent_state`  — a pane's agent state transitioned (idle/working/ready/done).
///  - `command`      — a shell command finished (OSC 133 D mark).
///  - `diff`         — a hook edit was queued / accepted / rejected.
struct SidekickEvent: Codable {
    let type: String
    let at: String

    var paneID: String?
    var tabID: String?
    var state: String?
    var command: String?
    var exitCode: Int?
    var duration: Double?
    var path: String?
    var decision: String?

    enum CodingKeys: String, CodingKey {
        case type, at, state, command, duration, path, decision
        case paneID = "pane_id"
        case tabID = "tab_id"
        case exitCode = "exit_code"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(type: String, at: Date = Date()) {
        self.type = type
        self.at = Self.timestampFormatter.string(from: at)
    }
}

/// Fans live app events out to every connected `events --follow` client as
/// newline-delimited JSON. The IPC accept loop hands a subscribed socket here
/// (after the same UID check every command gets); `AutomationCoordinator` — the
/// single place that already sees every state change, command mark, and diff —
/// feeds events in through `emit`.
///
/// Lifecycle: the connection's own IPC thread registers the FD, then blocks
/// reading it (a client never sends on an event stream) so EOF unblocks promptly
/// for cleanup. That reader thread is the *sole owner* of `close`. `emit` runs on
/// the main thread (notifications fire there); to a dead or wedged consumer it
/// `shutdown`s the socket — never `close`s it — so the owning reader closes it
/// and no FD number can be reused out from under an in-flight write.
// @unchecked Sendable: all mutable state (`subscribers`) is accessed only under
// `lock`, so this is safe to share across the main thread (where `emit` runs)
// and the per-connection IPC threads (which add/remove subscribers). The unsafe
// FD writes are serialized by the same lock-guarded membership set. Marked
// explicitly to prep for the Swift 6 strict-concurrency migration without
// flipping the language mode yet.
final class EventBroadcaster: @unchecked Sendable {
    static let shared = EventBroadcaster()

    private let lock = NSLock()
    private var subscribers: Set<Int32> = []

    private init() {}

    /// True while at least one client is following. Lets the emit sites skip
    /// building events nobody is listening for.
    var hasSubscribers: Bool {
        lock.lock(); defer { lock.unlock() }
        return !subscribers.isEmpty
    }

    /// Registers a subscriber socket and greets it. Called on the connection's
    /// IPC thread, which then blocks reading the socket until the client hangs
    /// up and calls `removeSubscriber`.
    func addSubscriber(_ fd: Int32) {
        lock.lock()
        subscribers.insert(fd)
        lock.unlock()
        send(SidekickEvent(type: "hello"), to: fd)
    }

    /// Called by the owning reader thread once its socket reaches EOF. The sole
    /// `close` site, so a `shutdown` from `emit` can't race FD reuse.
    func removeSubscriber(_ fd: Int32) {
        lock.lock()
        subscribers.remove(fd)
        lock.unlock()
        close(fd)
    }

    /// Serializes `event` to one JSON line and writes it to every subscriber.
    func emit(_ event: SidekickEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))

        lock.lock()
        let targets = subscribers
        lock.unlock()
        for fd in targets {
            send(line: line, to: fd)
        }
    }

    // MARK: - Writing

    private func send(_ event: SidekickEvent, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        send(line: line, to: fd)
    }

    /// Writes one already-framed line. If the socket isn't immediately writable
    /// (slow/wedged consumer) or the write fails, drops the subscriber from the
    /// active set and `shutdown`s it so the owning reader closes it.
    private func send(line: Data, to fd: Int32) {
        guard isWritable(fd) else {
            drop(fd)
            return
        }
        let wrote = line.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var cursor = base
            var remaining = raw.count
            while remaining > 0 {
                let count = write(fd, cursor, remaining)
                guard count > 0 else { return false }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
            return true
        }
        if !wrote { drop(fd) }
    }

    /// Non-blocking readiness probe so `emit` never stalls the main thread on a
    /// consumer that stopped draining.
    private func isWritable(_ fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&pfd, 1, 0) > 0 && (pfd.revents & Int16(POLLOUT)) != 0
    }

    /// Removes from the active set and `shutdown`s (does not close — the reader
    /// owns that) so a wedged consumer's socket unblocks for cleanup.
    private func drop(_ fd: Int32) {
        lock.lock()
        let wasActive = subscribers.remove(fd) != nil
        lock.unlock()
        if wasActive {
            shutdown(fd, SHUT_RDWR)
        }
    }
}
