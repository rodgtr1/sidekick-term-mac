import Cocoa

/// NSTextView subclass for the GUI file editor that adds a curated set of
/// VS Code-style line-editing shortcuts. These only apply to the editor view;
/// the terminal (including nvim) is a different view and is unaffected.
///
/// Shortcuts:
///   ⌥↑ / ⌥↓        move line(s) up / down
///   ⇧⌥↑ / ⇧⌥↓      duplicate line(s) up / down
///   ⇧⌘K            delete line(s)
///   ⌘/             toggle line comment
///   ⌘] / ⌘[        indent / outdent
///   Tab / ⇧Tab     indent / outdent selection (insert spaces when no selection)
class CodeTextView: NSTextView {

    /// Line-comment prefix for the current file (includes trailing space, e.g. "// ").
    var commentPrefix: String = "// "

    /// String inserted for one indent level.
    var indentString: String = "    "

    /// Number of spaces that make up one indent level (used when outdenting).
    var indentWidth: Int = 4

    // MARK: - Key handling

    // Hardware key codes (US layout, but these are physical-position codes).
    private enum Key {
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let tab: UInt16 = 48
        static let k: UInt16 = 40
        static let slash: UInt16 = 44
        static let leftBracket: UInt16 = 33
        static let rightBracket: UInt16 = 30
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = event.keyCode

        switch (flags, code) {
        case ([.option], Key.downArrow):
            moveSelectedLines(down: true); return
        case ([.option], Key.upArrow):
            moveSelectedLines(down: false); return
        case ([.option, .shift], Key.downArrow):
            duplicateSelectedLines(down: true); return
        case ([.option, .shift], Key.upArrow):
            duplicateSelectedLines(down: false); return
        case ([.command, .shift], Key.k):
            deleteSelectedLines(); return
        case ([.command], Key.slash):
            toggleComment(); return
        case ([.command], Key.rightBracket):
            reindent(add: true); return
        case ([.command], Key.leftBracket):
            reindent(add: false); return
        case ([], Key.tab):
            handleTab(shift: false); return
        case ([.shift], Key.tab):
            handleTab(shift: true); return
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Line operations

    private func moveSelectedLines(down: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)

        if down {
            guard NSMaxRange(block) < ns.length else { return }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            let blockStr = ns.substring(with: block)
            let nextStr = ns.substring(with: next)
            let combined = NSRange(location: block.location, length: NSMaxRange(next) - block.location)

            let newText: String
            let delta: Int
            if nextStr.hasSuffix("\n") {
                newText = nextStr + blockStr
                delta = (nextStr as NSString).length
            } else {
                // Block has a trailing newline, the (last) next line does not.
                newText = nextStr + "\n" + String(blockStr.dropLast())
                delta = (nextStr as NSString).length + 1
            }
            let newSel = NSRange(location: sel.location + delta, length: sel.length)
            replaceText(in: combined, with: newText, selection: newSel)
        } else {
            guard block.location > 0 else { return }
            let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let blockStr = ns.substring(with: block)
            let prevStr = ns.substring(with: prev)
            let combined = NSRange(location: prev.location, length: NSMaxRange(block) - prev.location)

            let newText: String
            if blockStr.hasSuffix("\n") {
                newText = blockStr + prevStr
            } else {
                // Block is the last line without a trailing newline.
                newText = blockStr + "\n" + String(prevStr.dropLast())
            }
            let delta = (prevStr as NSString).length
            let newSel = NSRange(location: sel.location - delta, length: sel.length)
            replaceText(in: combined, with: newText, selection: newSel)
        }
    }

    private func duplicateSelectedLines(down: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        let blockStr = ns.substring(with: block)
        let hasTrailingNewline = blockStr.hasSuffix("\n")

        if down {
            let insertText = hasTrailingNewline ? blockStr : "\n" + blockStr
            let insertLoc = NSMaxRange(block)
            let dupStart = hasTrailingNewline ? insertLoc : insertLoc + 1
            let offsetInBlock = sel.location - block.location
            let newSel = NSRange(location: dupStart + offsetInBlock, length: sel.length)
            replaceText(in: NSRange(location: insertLoc, length: 0), with: insertText, selection: newSel)
        } else {
            // Insert a copy above; the cursor stays put and lands on the upper copy.
            let insertText = hasTrailingNewline ? blockStr : blockStr + "\n"
            replaceText(in: NSRange(location: block.location, length: 0), with: insertText, selection: sel)
        }
    }

    private func deleteSelectedLines() {
        let ns = string as NSString
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        let blockStr = ns.substring(with: block)

        var deleteRange = block
        if !blockStr.hasSuffix("\n") && block.location > 0 {
            // Last line without a trailing newline: also remove the preceding
            // newline so we don't leave a dangling blank line.
            deleteRange = NSRange(location: block.location - 1, length: block.length + 1)
        }
        replaceText(in: deleteRange, with: "", selection: NSRange(location: deleteRange.location, length: 0))
    }

    private func reindent(add: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        let blockStr = ns.substring(with: block)
        let endsWithNewline = blockStr.hasSuffix("\n")

        var lines = blockStr.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }

        var firstDelta = 0
        var totalDelta = 0
        for i in lines.indices {
            if add {
                lines[i] = indentString + lines[i]
                let d = (indentString as NSString).length
                if i == 0 { firstDelta = d }
                totalDelta += d
            } else {
                let removed = removeLeadingIndent(&lines[i])
                if i == 0 { firstDelta = -removed }
                totalDelta -= removed
            }
        }

        var newText = lines.joined(separator: "\n")
        if endsWithNewline { newText += "\n" }

        let newStart = max(block.location, sel.location + firstDelta)
        let newLen = max(0, sel.length + (totalDelta - firstDelta))
        replaceText(in: block, with: newText, selection: NSRange(location: newStart, length: newLen))
    }

    private func handleTab(shift: Bool) {
        let ns = string as NSString
        let sel = selectedRange()

        if shift {
            reindent(add: false)
            return
        }
        if ns.substring(with: sel).contains("\n") {
            reindent(add: true)
            return
        }
        // No multi-line selection: insert one indent level at the cursor.
        let newSel = NSRange(location: sel.location + (indentString as NSString).length, length: 0)
        replaceText(in: sel, with: indentString, selection: newSel)
    }

    private func toggleComment() {
        let ns = string as NSString
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        let blockStr = ns.substring(with: block)
        let endsWithNewline = blockStr.hasSuffix("\n")

        var lines = blockStr.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }

        let trimmedPrefix = commentPrefix.trimmingCharacters(in: .whitespaces)
        let contentIndices = lines.indices.filter {
            !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !contentIndices.isEmpty else { return }

        let allCommented = contentIndices.allSatisfy {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(trimmedPrefix)
        }
        for i in contentIndices {
            lines[i] = allCommented ? uncommentLine(lines[i]) : commentLine(lines[i])
        }

        var newText = lines.joined(separator: "\n")
        if endsWithNewline { newText += "\n" }

        let newSel = NSRange(location: block.location, length: (newText as NSString).length)
        replaceText(in: block, with: newText, selection: newSel)
    }

    // MARK: - Helpers

    private func commentLine(_ line: String) -> String {
        let idx = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
        return String(line[line.startIndex..<idx]) + commentPrefix + String(line[idx...])
    }

    private func uncommentLine(_ line: String) -> String {
        let trimmedPrefix = commentPrefix.trimmingCharacters(in: .whitespaces)
        let idx = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
        let leading = String(line[line.startIndex..<idx])
        var rest = String(line[idx...])
        if rest.hasPrefix(commentPrefix) {
            rest = String(rest.dropFirst(commentPrefix.count))
        } else if rest.hasPrefix(trimmedPrefix) {
            rest = String(rest.dropFirst(trimmedPrefix.count))
            if rest.hasPrefix(" ") { rest = String(rest.dropFirst()) }
        }
        return leading + rest
    }

    /// Removes up to one indent level of leading whitespace. Returns the number
    /// of UTF-16 units removed.
    private func removeLeadingIndent(_ line: inout String) -> Int {
        if line.hasPrefix("\t") {
            line.removeFirst()
            return 1
        }
        var removed = 0
        while removed < indentWidth, line.hasPrefix(" ") {
            line.removeFirst()
            removed += 1
        }
        return removed
    }

    /// Applies an edit through the undo-aware text-change machinery, then
    /// restores a clamped selection.
    private func replaceText(in range: NSRange, with replacement: String, selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()

        let length = (string as NSString).length
        let location = min(selection.location, length)
        let clamped = NSRange(location: location, length: min(selection.length, length - location))
        setSelectedRange(clamped)
    }

    /// Line-comment prefix for a file extension (trailing space included).
    static func commentPrefix(forExtension ext: String) -> String {
        switch ext {
        case "py", "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml",
             "ini", "cfg", "conf", "r", "pl", "pm", "tcl", "coffee", "ps1",
             "makefile", "dockerfile", "gitignore", "env", "properties":
            return "# "
        case "lua", "sql", "hs", "elm", "ada", "vhdl":
            return "-- "
        case "lisp", "clj", "cljs", "el", "scm":
            return "; "
        case "vim":
            return "\" "
        default:
            return "// "
        }
    }
}
