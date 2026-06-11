import Cocoa

/// Sheet that shows a proposed file edit (from the Claude Code PreToolUse
/// hook) and asks the user to accept or reject it. The completion is held
/// until the user decides, which in turn holds the hook's IPC response.
final class DiffApprovalPanel {
    private var completion: ((Bool) -> Void)?
    private var sheet: NSWindow?
    private weak var parentWindow: NSWindow?

    func show(
        relativeTo window: NSWindow,
        path: String,
        old: String,
        new: String,
        completion: @escaping (Bool) -> Void
    ) {
        self.completion = completion
        self.parentWindow = window

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Proposed Edit"

        let content = NSView()
        sheet.contentView = content

        let theme = Theme.shared.current
        content.wantsLayer = true
        content.layer?.backgroundColor = theme.windowBackground.cgColor

        let titleLabel = NSTextField(labelWithString: "Agent wants to edit:")
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = theme.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: abbreviatePath(path))
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        pathLabel.textColor = theme.primaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.windowBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = theme.windowBackground
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        // Diff generation shells out to /usr/bin/diff; keep it off the main
        // thread so a large edit doesn't beachball the app while the sheet
        // comes up.
        textView.string = "Computing diff…"
        DispatchQueue.global(qos: .userInitiated).async { [weak textView] in
            let diffText = Self.unifiedDiff(old: old, new: new, path: path)
            let rendered = InlineDiffRenderer.render(diffText)
            DispatchQueue.main.async {
                textView?.textStorage?.setAttributedString(rendered)
            }
        }

        let rejectButton = NSButton(title: "Reject", target: self, action: #selector(rejectClicked))
        rejectButton.keyEquivalent = "\u{1b}"
        rejectButton.bezelStyle = .rounded
        rejectButton.translatesAutoresizingMaskIntoConstraints = false

        let acceptButton = NSButton(title: "Accept", target: self, action: #selector(acceptClicked))
        acceptButton.keyEquivalent = "\r"
        acceptButton.bezelStyle = .rounded
        acceptButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleLabel)
        content.addSubview(pathLabel)
        content.addSubview(scrollView)
        content.addSubview(rejectButton)
        content.addSubview(acceptButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            pathLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: acceptButton.topAnchor, constant: -12),

            acceptButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            acceptButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            acceptButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            rejectButton.trailingAnchor.constraint(equalTo: acceptButton.leadingAnchor, constant: -8),
            rejectButton.bottomAnchor.constraint(equalTo: acceptButton.bottomAnchor),
            rejectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])

        self.sheet = sheet
        window.beginSheet(sheet)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.requestUserAttention(.criticalRequest)
    }

    @objc private func acceptClicked() {
        finish(accepted: true)
    }

    @objc private func rejectClicked() {
        finish(accepted: false)
    }

    /// Tears the sheet down and reports rejection — used when the parent
    /// window closes so the held IPC completion is never stranded.
    func cancel() {
        finish(accepted: false)
    }

    private func finish(accepted: Bool) {
        if let sheet = sheet {
            parentWindow?.endSheet(sheet)
        }
        sheet = nil
        completion?(accepted)
        completion = nil
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Produces a unified diff of two strings with /usr/bin/diff. Falls back
    /// to a whole-file remove/add diff if that fails.
    static func unifiedDiff(old: String, new: String, path: String) -> String {
        let temp = FileManager.default.temporaryDirectory
        let oldURL = temp.appendingPathComponent("sidekick-diff-old-\(UUID().uuidString)")
        let newURL = temp.appendingPathComponent("sidekick-diff-new-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }

        let fileName = (path as NSString).lastPathComponent
        do {
            try old.write(to: oldURL, atomically: true, encoding: .utf8)
            try new.write(to: newURL, atomically: true, encoding: .utf8)

            let result = try ProcessRunner.shared.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/diff"),
                arguments: ["-u", oldURL.path, newURL.path]
            )

            // diff exits 1 when files differ — that's the expected case.
            if result.terminationStatus <= 1 {
                var output = result.stdout
                    .replacingOccurrences(of: oldURL.path, with: "a/\(fileName)")
                    .replacingOccurrences(of: newURL.path, with: "b/\(fileName)")
                if output.isEmpty {
                    output = "--- a/\(fileName)\n+++ b/\(fileName)\n(no changes)\n"
                }
                return output
            }
        } catch {
            print("DiffApprovalPanel: diff failed: \(error)")
        }

        // Fallback: whole-file replacement view.
        var lines = ["--- a/\(fileName)", "+++ b/\(fileName)"]
        lines.append("@@ -1 +1 @@")
        lines.append(contentsOf: old.split(separator: "\n", omittingEmptySubsequences: false).map { "-\($0)" })
        lines.append(contentsOf: new.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" })
        return lines.joined(separator: "\n")
    }
}
