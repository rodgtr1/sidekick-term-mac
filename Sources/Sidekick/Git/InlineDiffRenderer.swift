import Cocoa

/// Renders unified git diff text as a Zed-style inline diff:
/// - file metadata (diff --git, index, ---, +++) is hidden
/// - removed lines sit directly above their replacements with a light red
///   background and no line number
/// - added lines carry the new file's line number on a light green background
/// - for paired removed/added lines, the changed character range is
///   emphasized with a stronger red/green
enum InlineDiffRenderer {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static let textColor = NSColor(hex: "#cdd6f4") ?? .textColor
    private static let gutterColor = NSColor(hex: "#6c7086") ?? .secondaryLabelColor
    private static let separatorColor = NSColor(hex: "#45475a") ?? .separatorColor
    private static let removedLineBG = (NSColor(hex: "#f38ba8") ?? .systemRed).withAlphaComponent(0.13)
    private static let removedEmphasisBG = (NSColor(hex: "#f38ba8") ?? .systemRed).withAlphaComponent(0.42)
    private static let addedLineBG = (NSColor(hex: "#a6e3a1") ?? .systemGreen).withAlphaComponent(0.13)
    private static let addedEmphasisBG = (NSColor(hex: "#a6e3a1") ?? .systemGreen).withAlphaComponent(0.38)

    private static let gutterWidth = 5
    private static var blankGutter: String { String(repeating: " ", count: gutterWidth) + "  " }

    static func render(_ diff: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        var newLineNumber = 0
        var insideHunk = false
        var renderedAnyHunk = false
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("diff --git") {
                insideHunk = false
                index += 1
                continue
            }

            if line.hasPrefix("@@") {
                newLineNumber = parseNewStart(line) ?? newLineNumber
                if renderedAnyHunk {
                    appendSeparator(to: result)
                }
                insideHunk = true
                renderedAnyHunk = true
                index += 1
                continue
            }

            if !insideHunk {
                // Everything between "diff --git" and the first @@ is metadata.
                index += 1
                continue
            }

            if line.hasPrefix("-") {
                var removed: [String] = []
                while index < lines.count, lines[index].hasPrefix("-") {
                    removed.append(String(lines[index].dropFirst()))
                    index += 1
                }
                var added: [String] = []
                while index < lines.count, lines[index].hasPrefix("+") {
                    added.append(String(lines[index].dropFirst()))
                    index += 1
                }
                appendChangeBlock(removed: removed, added: added, newLineNumber: &newLineNumber, to: result)
                continue
            }

            if line.hasPrefix("+") {
                var added: [String] = []
                while index < lines.count, lines[index].hasPrefix("+") {
                    added.append(String(lines[index].dropFirst()))
                    index += 1
                }
                appendChangeBlock(removed: [], added: added, newLineNumber: &newLineNumber, to: result)
                continue
            }

            if line.hasPrefix("\\") {
                // "\ No newline at end of file"
                index += 1
                continue
            }

            // Context line (leading space in unified format).
            let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            appendLine(content, number: newLineNumber, lineBG: nil, emphasis: nil, emphasisBG: nil, to: result)
            newLineNumber += 1
            index += 1
        }

        if result.length == 0 {
            result.append(NSAttributedString(string: "No changes", attributes: [
                .font: font,
                .foregroundColor: gutterColor
            ]))
        }
        return result
    }

    // MARK: - Blocks

    private static func appendChangeBlock(
        removed: [String],
        added: [String],
        newLineNumber: inout Int,
        to result: NSMutableAttributedString
    ) {
        let pairCount = min(removed.count, added.count)

        // Removed lines first (the "before" block), with emphasis computed
        // against the paired replacement line.
        for (offset, removedLine) in removed.enumerated() {
            var emphasis: NSRange?
            if offset < pairCount {
                emphasis = intralineDifference(removedLine, added[offset]).old
            }
            appendLine(removedLine, number: nil, lineBG: removedLineBG, emphasis: emphasis, emphasisBG: removedEmphasisBG, to: result)
        }

        for (offset, addedLine) in added.enumerated() {
            var emphasis: NSRange?
            if offset < pairCount {
                emphasis = intralineDifference(removed[offset], addedLine).new
            }
            appendLine(addedLine, number: newLineNumber, lineBG: addedLineBG, emphasis: emphasis, emphasisBG: addedEmphasisBG, to: result)
            newLineNumber += 1
        }
    }

    /// Common-prefix/suffix character diff between a removed and added line,
    /// in UTF-16 units. Returns nil ranges when the lines are too different
    /// for an emphasized middle to be meaningful.
    static func intralineDifference(_ old: String, _ new: String) -> (old: NSRange?, new: NSRange?) {
        let oldChars = Array(old.utf16)
        let newChars = Array(new.utf16)
        guard !oldChars.isEmpty, !newChars.isEmpty else { return (nil, nil) }

        var prefix = 0
        let minCount = min(oldChars.count, newChars.count)
        while prefix < minCount && oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < minCount - prefix
                && oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let oldRange = NSRange(location: prefix, length: oldChars.count - prefix - suffix)
        let newRange = NSRange(location: prefix, length: newChars.count - prefix - suffix)

        // If most of the line changed, whole-line tinting reads better than
        // a giant emphasis blob.
        let longest = max(oldChars.count, newChars.count)
        if max(oldRange.length, newRange.length) > Int(Double(longest) * 0.7) {
            return (nil, nil)
        }

        return (
            oldRange.length > 0 ? oldRange : nil,
            newRange.length > 0 ? newRange : nil
        )
    }

    // MARK: - Line rendering

    private static func appendLine(
        _ content: String,
        number: Int?,
        lineBG: NSColor?,
        emphasis: NSRange?,
        emphasisBG: NSColor?,
        to result: NSMutableAttributedString
    ) {
        let gutter: String
        if let number = number {
            gutter = String(repeating: " ", count: max(0, gutterWidth - "\(number)".count)) + "\(number)  "
        } else {
            gutter = blankGutter
        }

        let lineStart = result.length
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        if let lineBG = lineBG {
            attributes[.backgroundColor] = lineBG
        }

        let lineString = NSMutableAttributedString(string: gutter + content + "\n", attributes: attributes)
        lineString.addAttribute(
            .foregroundColor,
            value: gutterColor,
            range: NSRange(location: 0, length: gutter.count)
        )
        result.append(lineString)

        if let emphasis = emphasis, let emphasisBG = emphasisBG {
            let shifted = NSRange(location: lineStart + gutter.count + emphasis.location, length: emphasis.length)
            if shifted.location + shifted.length <= result.length {
                result.addAttribute(.backgroundColor, value: emphasisBG, range: shifted)
            }
        }
    }

    private static func appendSeparator(to result: NSMutableAttributedString) {
        result.append(NSAttributedString(string: "\(blankGutter)⋯\n", attributes: [
            .font: font,
            .foregroundColor: separatorColor
        ]))
    }

    private static func parseNewStart(_ hunkHeader: String) -> Int? {
        // @@ -oldStart,oldCount +newStart,newCount @@
        guard let plusIndex = hunkHeader.firstIndex(of: "+") else { return nil }
        let tail = hunkHeader[hunkHeader.index(after: plusIndex)...]
        let digits = tail.prefix(while: { $0.isNumber })
        return Int(digits)
    }
}
