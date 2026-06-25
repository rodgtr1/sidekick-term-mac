import Foundation

/// How long a user-granted "approve & remember" allowance lasts. Every scope
/// is session-only (cleared on relaunch), matching the Auto-approve Agent Edits
/// menu toggle — nothing here is persisted to disk.
enum RememberScope: String {
    case none       // Just this once
    case file       // This exact file, rest of session
    case folder     // This folder and everything under it, rest of session
    case session    // Every edit, rest of session (same as the menu toggle)
}

/// The outcome of a diff-approval sheet: whether the edit was accepted, and
/// whether the user asked to remember the decision for similar future edits.
struct ApprovalOutcome {
    let accepted: Bool
    let remember: RememberScope

    static let rejected = ApprovalOutcome(accepted: false, remember: .none)
}

/// Session-scoped allowances the user granted through "approve & remember".
/// In-memory only; relaunch resets it.
struct SessionApprovals {
    var sessionWide = false
    private(set) var files: Set<String> = []
    private(set) var folders: [String] = []

    mutating func record(_ scope: RememberScope, path: String) {
        switch scope {
        case .none:
            break
        case .file:
            files.insert(path)
        case .folder:
            folders.append((path as NSString).deletingLastPathComponent)
        case .session:
            sessionWide = true
        }
    }

    func allows(_ path: String) -> Bool {
        if sessionWide { return true }
        if files.contains(path) { return true }
        return folders.contains { folder in
            path == folder || path.hasPrefix(folder + "/")
        }
    }
}

/// Decides whether an agent edit to a given path is approved silently or needs
/// the review sheet. Precedence, highest first:
///   1. `always_ask` globs — always prompt. A security override: an entry like
///      `.env` keeps prompting even in auto mode or after a "remember" grant.
///   2. session "approve & remember" allowances.
///   3. `auto_allow` globs — silent approve even while the global mode is "ask".
///   4. global auto toggle — the `[approval] mode` config plus the menu toggle.
enum ApprovalPolicy {
    enum Decision { case ask, allow }

    static func decide(
        path: String,
        globalAuto: Bool,
        autoAllow: [String],
        alwaysAsk: [String],
        session: SessionApprovals
    ) -> Decision {
        if alwaysAsk.contains(where: { glob($0, matches: path) }) { return .ask }
        if session.allows(path) { return .allow }
        if autoAllow.contains(where: { glob($0, matches: path) }) { return .allow }
        return globalAuto ? .allow : .ask
    }

    /// Glob match supporting `**` (spans `/`), `*` (within a single path
    /// segment), and `?`. A pattern with a leading `/` or `~` is anchored to
    /// the full path; otherwise it matches anywhere in the tree on a `/`
    /// boundary, so `Sources/**` matches `/repo/Sources/x.swift` and `.env`
    /// matches `/repo/.env`.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        let normalizedPath = (path as NSString).expandingTildeInPath
        let expandedPattern = (pattern as NSString).expandingTildeInPath
        let anchored = expandedPattern.hasPrefix("/")
        let body = regexBody(expandedPattern)
        let prefix = anchored ? "^" : "(^|/)"
        guard let regex = try? NSRegularExpression(pattern: prefix + body + "$") else {
            return false
        }
        let range = NSRange(normalizedPath.startIndex..., in: normalizedPath)
        return regex.firstMatch(in: normalizedPath, range: range) != nil
    }

    /// Translates a glob into a regex fragment (no anchors).
    private static func regexBody(_ pattern: String) -> String {
        var result = ""
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    result += ".*"          // ** spans path separators
                    i += 2
                    if i < chars.count && chars[i] == "/" { i += 1 }  // swallow the trailing slash
                    continue
                }
                result += "[^/]*"           // * stays within one segment
            case "?":
                result += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                result += "\\" + String(c)
            default:
                result += String(c)
            }
            i += 1
        }
        return result
    }
}
