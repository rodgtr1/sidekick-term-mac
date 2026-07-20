import Cocoa

protocol SessionsPanelDelegate: AnyObject {
    /// The user chose a past session to resume (Return or double-click).
    func sessionsPanel(_ panel: SessionsPanel, didSelect record: SessionRecord)
}

/// ⌃⇧S Session Recall: lists past Claude/Codex sessions newest-first,
/// filters as you type, and on Enter resumes the selected one in a new tab.
/// The panel chrome (search field, table, key handling) lives in
/// `FilterableListPanel`; this subclass supplies the records and the async
/// cache load. Data (parse/cache/query) lives in the rest of `SessionRecall/`.
final class SessionsPanel: FilterableListPanel {
    weak var sessionsDelegate: SessionsPanelDelegate?

    /// Every record from the last cache refresh, unfiltered.
    private var all: [SessionRecord] = []
    /// The records currently shown, after applying the search query.
    private var filtered: [SessionRecord] = []
    /// The query in effect, re-applied when a background refresh lands.
    private var currentQuery: String = ""
    /// Cap the rows shown. The list is sorted newest-first, so this surfaces the
    /// most recent sessions by default; typing narrows across all of them. Keeps
    /// the panel a quick pick instead of an endless scroll.
    private let displayLimit = 50

    init() {
        super.init(chrome: Chrome(
            title: "Sessions",
            placeholder: "Search past sessions…",
            size: NSSize(width: 620, height: 420),
            columnIdentifier: "SessionRecord",
            hidesOnDeactivate: true,
            // Two-line rows (title + "agent · repo · age") need more than the
            // single-line default, or the subtitle clips into the next row.
            rowHeight: 46
        ))
    }

    // MARK: - FilterableListPanel hooks

    override var itemCount: Int { filtered.count }

    override func cellView(forRow row: Int) -> NSView? {
        let cell = SessionRowCellView()
        cell.configure(with: filtered[row])
        return cell
    }

    override func queryChanged(_ query: String) {
        currentQuery = query
        applyFilter()
        reloadAndSelectFirst()
    }

    override func activateRow(_ row: Int) {
        let record = filtered[row]
        close()
        sessionsDelegate?.sessionsPanel(self, didSelect: record)
    }

    private func applyFilter() {
        filtered = SessionQuery.run(
            all,
            search: currentQuery.isEmpty ? nil : currentQuery,
            limit: displayLimit
        )
        // Reflect the cap in the title bar so the list never silently hides
        // matches — "Sessions · 50 of 334" tells you to type to reach the rest.
        let total = currentQuery.isEmpty ? all.count : SessionQuery.run(all, search: currentQuery).count
        title = filtered.count < total ? "Sessions · \(filtered.count) of \(total)" : "Sessions"
    }

    func show(relativeTo parentWindow: NSWindow) {
        let parentFrame = parentWindow.frame
        setFrameOrigin(NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: parentFrame.midY + 80
        ))

        searchField.stringValue = ""
        currentQuery = ""
        // Show immediately with whatever we already have; the refresh below
        // repopulates once the (off-main) cache load lands.
        applyFilter()
        reloadAndSelectFirst()

        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()

        loadSessions()
    }

    /// Refresh the unified session list off the main thread (the module is
    /// `@MainActor` by default, but the cache/parse/query types are
    /// `nonisolated`/`Sendable`), then apply on main — mirroring how
    /// `QuickOpenPanel` drains work off-main and applies on main.
    private func loadSessions() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeRoot = home.appendingPathComponent(".claude/projects")
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let cacheURL = SessionRecallCache.defaultCacheURL()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let records = SessionRecallCache.refresh(
                claudeProjectsRoot: claudeRoot,
                codexSessionsRoot: codexRoot,
                cacheURL: cacheURL
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = records
                self.applyFilter()
                self.reloadAndSelectFirst()
            }
        }
    }
}

// MARK: - Row cell

/// One session row: an agent glyph, the (aiTitle-preferred) title, and a muted
/// subtitle of "agent · repo · relative age". Modeled on the palette's
/// `PaletteActionCellView`, using `AppTheme` colors.
private final class SessionRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = AppTheme.accent

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = AppTheme.mutedText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    func configure(with record: SessionRecord) {
        let symbol = record.agent == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: record.agent.rawValue)
        titleLabel.stringValue = record.aiTitle ?? record.title
        subtitleLabel.stringValue = Self.subtitle(for: record)
    }

    private static func subtitle(for record: SessionRecord) -> String {
        var parts: [String] = [record.agent.rawValue]
        if let repo = record.repo, !repo.isEmpty {
            parts.append(repo)
        }
        if let age = relativeAge(record.timestamp) {
            parts.append(age)
        }
        return parts.joined(separator: " · ")
    }

    private static func relativeAge(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ageFormatter.localizedString(for: date, relativeTo: Date())
    }
}
