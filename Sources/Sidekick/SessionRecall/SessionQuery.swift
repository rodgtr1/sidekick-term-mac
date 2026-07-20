import Foundation

/// A pure, in-memory filter+sort over `[SessionRecord]`, mirroring the Phase 0
/// Python prototype's query semantics (`scripts/session-recall-scan.py`:
/// `--agent` / `--repo` / `--search` / `--limit`, newest-first).
///
/// Stateless and `nonisolated` so it can run off the main thread despite the
/// module's `@MainActor` default isolation.
nonisolated enum SessionQuery {
    /// Filter, sort newest-first, and optionally cap `records`.
    ///
    /// - Parameters:
    ///   - agent: keep only this agent's sessions, when set.
    ///   - repo: case-insensitive substring matched against each record's repo
    ///     OR cwd.
    ///   - search: case-insensitive substring matched against title OR aiTitle
    ///     OR cwd.
    ///   - limit: cap applied *after* sorting; a negative limit is ignored.
    static func run(
        _ records: [SessionRecord],
        agent: SessionAgent? = nil,
        repo: String? = nil,
        search: String? = nil,
        limit: Int? = nil
    ) -> [SessionRecord] {
        var results = records

        if let agent {
            results = results.filter { $0.agent == agent }
        }

        if let repo, !repo.isEmpty {
            let needle = repo.lowercased()
            results = results.filter { record in
                record.repo?.lowercased().contains(needle) == true
                    || record.cwd?.lowercased().contains(needle) == true
            }
        }

        if let search, !search.isEmpty {
            let needle = search.lowercased()
            results = results.filter { record in
                record.title.lowercased().contains(needle)
                    || record.aiTitle?.lowercased().contains(needle) == true
                    || record.cwd?.lowercased().contains(needle) == true
            }
        }

        // Newest first; records with no timestamp sink to the bottom.
        results.sort { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }

        if let limit, limit >= 0 {
            results = Array(results.prefix(limit))
        }

        return results
    }
}
