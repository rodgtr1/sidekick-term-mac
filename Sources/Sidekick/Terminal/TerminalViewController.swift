import Cocoa
import SwiftTerm

protocol TerminalViewControllerDelegate: AnyObject {
    func terminalDidUpdateTitle(_ terminal: TerminalViewController, directory: String, branch: String?)
    func terminalDidDetectAgentState(_ terminal: TerminalViewController, state: AgentState)
    func terminalDidUpdateCommandStatus(_ terminal: TerminalViewController, status: TerminalCommandStatus?)
    func terminalRequestsOpenURL(_ terminal: TerminalViewController, url: URL)
    func terminalRequestsOpenFile(_ terminal: TerminalViewController, path: String, line: Int?)
}

/// Result of the last finished shell command, reported via OSC 133 marks
/// from the shell integration script.
struct TerminalCommandStatus {
    let exitCode: Int
    let duration: TimeInterval?

    var succeeded: Bool { exitCode == 0 }

    var summary: String {
        let outcome = succeeded ? "✓ exit 0" : "✗ exit \(exitCode)"
        guard let duration = duration else { return outcome }
        if duration >= 60 {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(outcome) · \(minutes)m \(seconds)s"
        }
        return String(format: "%@ · %.1fs", outcome, duration)
    }
}

private final class AgentAwareTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    var onInput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if let output = String(bytes: slice, encoding: .utf8) {
            onOutput?(output)
        }
        super.dataReceived(slice: slice)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?()
        super.send(source: source, data: data)
    }
}

class TerminalViewController: NSViewController, LocalProcessTerminalViewDelegate {
    private static let agentStatusTermprop = "vte.ext.sidekick.agent"

    weak var delegate: TerminalViewControllerDelegate?
    private var terminalView: LocalProcessTerminalView!
    private var config: Config
    private var cwdTimer: Timer?
    private var currentCWD: String = "~"
    private var isUpdatingCWD = false

    // SwiftTerm tracks the exact child PID; scanning `ps` for "a child of
    // this app" breaks as soon as a second tab (or any transient child
    // process) exists.
    private var shellPID: pid_t {
        terminalView?.process?.shellPid ?? 0
    }
    private var initialDirectory: String?
    private var recentOutput = ""
    private var agentStatusSequenceBuffer = ""
    private var lastDetectedAgentState: AgentState = .idle
    // Once the session reports state via OSC 666 (Claude/Codex hooks), those
    // reports are authoritative and the text heuristics stand down.
    private var hasExplicitAgentStatus = false
    private var agentDoneTimer: Timer?
    private var pendingDetectionOutput = ""
    private var detectionFlushScheduled = false

    private var findBar: TerminalFindBar?
    private var scrollEventMonitor: Any?
    private var alternateScrollAccumulator: CGFloat = 0

    // Dev-server detection
    private var serverBannerView: NSView?
    private var serverBannerDismissWork: DispatchWorkItem?
    private var detectedServerURL: URL?
    private var lastOfferedServerURL: URL?

    private static let serverURLRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https?://(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0)(?::\\d{2,5})?(?:/[A-Za-z0-9_\\-./?#=&%]*)?"
    )
    private static let listeningPortRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?i)listening on (?:port )?(?:[a-z.*]*:)?(\\d{2,5})\\b"
    )

    // Shell integration (OSC 7 + OSC 133) state
    private var hasShellIntegration = false
    private var commandMarkBuffer = ""
    private var commandStartDate: Date?
    private var promptMarkRows: [Int] = []
    private static let maxPromptMarks = 500

    private static let commandMarkRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\]133;([A-Za-z])(?:;([^\u{001B}\u{0007}]*))?(?:\u{001B}\\\\|\u{0007})")

    private static let agentStatusRegex: NSRegularExpression? = {
        let escapedTermprop = NSRegularExpression.escapedPattern(for: agentStatusTermprop)
        let pattern = "\u{001B}\\]666;\(escapedTermprop)=([A-Za-z_-]+)(?:\u{001B}\\\\|\u{0007})"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let ansiEscapeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")

    init(config: Config, initialDirectory: String? = nil) {
        self.config = config
        self.initialDirectory = initialDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTerminal()
        startShell()
        startCWDTracking()
        setupAlternateScreenScrolling()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontZoomChanged),
            name: FontZoom.didChangeNotification,
            object: nil
        )
    }

    @objc private func fontZoomChanged() {
        terminalView.font = terminalFont(for: config)
    }

    /// The configured font with the app-wide zoom scale applied.
    private func terminalFont(for config: Config) -> NSFont {
        let size = CGFloat(Double(config.font.size) * FontZoom.shared.scale)
        return NSFont(name: config.font.family, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// SwiftTerm's scrollWheel only ever scrolls the scrollback buffer.
    /// That breaks two cases that other terminals handle:
    ///  - apps with mouse reporting enabled (Claude Code) expect wheel
    ///    events so they can scroll their own content;
    ///  - alternate-screen apps without mouse reporting (vim, less) have
    ///    no scrollback, so wheel events should become arrow keys.
    /// Plain shells still fall through to normal scrollback scrolling.
    private func setupAlternateScreenScrolling() {
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .leftMouseUp {
                return self.handleCommandMouseUp(event)
            }
            return self.handleScrollWheelEvent(event)
        }
    }

    /// Owns all ⌘+click behavior over the terminal: file paths open in the
    /// built-in editor, URLs open in the browser pane — and the event is
    /// swallowed so SwiftTerm's default handler can't also open links in
    /// the external browser (which made incidental ⌘-taps open pages).
    private func handleCommandMouseUp(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command),
              let window = view.window,
              event.window === window,
              let terminalView = terminalView,
              // Hidden tabs share window coordinates with the visible one;
              // without this, an invisible terminal swallows the click.
              !terminalView.isHiddenOrHasHiddenAncestor else { return event }

        let pointInView = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(pointInView) else { return event }

        let terminal = terminalView.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return nil }

        let cellWidth = max(1, terminalView.bounds.width / CGFloat(terminal.cols))
        let cellHeight = max(1, terminalView.bounds.height / CGFloat(terminal.rows))
        let col = min(terminal.cols - 1, max(0, Int(pointInView.x / cellWidth)))
        let row = min(terminal.rows - 1, max(0, Int((terminalView.bounds.height - pointInView.y) / cellHeight)))

        if handleCommandClick(col: col, row: row) {
            return nil
        }
        if let url = urlUnderClick(col: col, row: row) {
            delegate?.terminalRequestsOpenURL(self, url: url)
        }
        // Swallow every ⌘+mouse-up over the terminal either way.
        return nil
    }

    private static let clickableURLRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "https?://[^\\s\"'<>\\)\\]]+")

    private func urlUnderClick(col: Int, row: Int) -> URL? {
        guard let line = terminalView.getTerminal().getLine(row: row) else { return nil }
        let text = line.translateToString(trimRight: true)
        guard !text.isEmpty, let regex = Self.clickableURLRegex else { return nil }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard match.range.location <= col, col < match.range.location + match.range.length else { continue }
            var candidate = nsText.substring(with: match.range)
            // Trim punctuation that commonly trails URLs in prose.
            while let last = candidate.last, ".,;:!?".contains(last) {
                candidate.removeLast()
            }
            return URL(string: candidate)
        }
        return nil
    }

    private func handleScrollWheelEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = view.window,
              event.window === window,
              let terminalView = terminalView,
              // Hidden tabs share window coordinates with the visible one;
              // without this, an invisible terminal handles the scroll.
              !terminalView.isHiddenOrHasHiddenAncestor else { return event }

        let terminal = terminalView.getTerminal()
        let reportsMouse = terminal.mouseMode != .off
        guard reportsMouse || terminal.isCurrentBufferAlternate else { return event }

        // Only handle events over this terminal's view.
        let pointInView = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(pointInView) else { return event }

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate pixel deltas into whole cell rows.
            let cellHeight = max(1, terminalView.bounds.height / CGFloat(max(1, terminal.rows)))
            alternateScrollAccumulator += event.scrollingDeltaY
            let wholeLines = Int(alternateScrollAccumulator / cellHeight)
            guard wholeLines != 0 else { return nil }
            alternateScrollAccumulator -= CGFloat(wholeLines) * cellHeight
            lines = wholeLines
        } else {
            guard event.deltaY != 0 else { return nil }
            lines = Int(event.deltaY.rounded(.awayFromZero))
        }

        let scrollingUp = lines > 0
        let count = min(10, abs(lines))

        if reportsMouse {
            // Send wheel events at the hovered cell (xterm buttons 4/5).
            let col = min(terminal.cols - 1, max(0, Int(pointInView.x / max(1, terminalView.bounds.width / CGFloat(max(1, terminal.cols))))))
            let cellHeight = max(1, terminalView.bounds.height / CGFloat(max(1, terminal.rows)))
            let row = min(terminal.rows - 1, max(0, Int((terminalView.bounds.height - pointInView.y) / cellHeight)))
            let buttonFlags = terminal.encodeButton(
                button: scrollingUp ? 4 : 5,
                release: false,
                shift: event.modifierFlags.contains(.shift),
                meta: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control)
            )
            for _ in 0..<count {
                terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
            }
        } else {
            // Alternate screen without mouse reporting: arrow keys.
            let sequence = terminal.applicationCursor
                ? (scrollingUp ? "\u{1B}OA" : "\u{1B}OB")
                : (scrollingUp ? "\u{1B}[A" : "\u{1B}[B")
            terminalView.send(txt: String(repeating: sequence, count: count))
        }
        return nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Focus terminal after view appears
        focusTerminal()
    }

    private func setupTerminal() {
        let font = terminalFont(for: config)

        print("🔤 Terminal font: \(font.fontName) size: \(font.pointSize)")

        let agentAwareTerminalView = AgentAwareTerminalView(frame: view.bounds)
        agentAwareTerminalView.onOutput = { [weak self] output in
            DispatchQueue.main.async {
                self?.queueAgentDetection(output)
            }
        }
        agentAwareTerminalView.onInput = { [weak self] in
            DispatchQueue.main.async {
                self?.handleTerminalInput()
            }
        }
        terminalView = agentAwareTerminalView
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.font = font
        terminalView.useBrightColors = config.font.boldIsBright

        // Keep the first 16 ANSI colors themed, but leave 256-color indexes on
        // the standard xterm cube so CLI theme pickers render selected colors faithfully.
        terminalView.terminal.ansi256PaletteStrategy = .xterm
        terminalView.installColors(ColorPalette.catppuccinMocha)

        // Set terminal foreground and background colors
        terminalView.nativeForegroundColor = NSColor(hex: "#cdd6f4")!  // Catppuccin text

        // Apply background based on blur configuration
        terminalView.wantsLayer = true
        applyTerminalAppearance(config)

        // Set caret (cursor) color
        terminalView.caretColor = NSColor(hex: "#f5e0dc")!  // Catppuccin rosewater

        // Set delegate to receive process events
        terminalView.processDelegate = self

        setupURLHandling()

        view.addSubview(terminalView)

        // Apply padding from config
        let padding = CGFloat(config.window.padding)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding)
        ])
    }

    private func startShell() {
        let shell = getShell()
        let shellIdiom = "-" + NSString(string: shell).lastPathComponent
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path

        // Use initialDirectory if provided, otherwise use home directory.
        // Validate before handing it to SwiftTerm so a stale tracked cwd falls back cleanly.
        let requestedDirectory = initialDirectory ?? homeDirectory
        var isDirectory: ObjCBool = false
        let startDirectory: String
        if FileManager.default.fileExists(atPath: requestedDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            startDirectory = requestedDirectory
        } else {
            startDirectory = homeDirectory
        }

        currentCWD = startDirectory

        // Start the shell with SwiftTerm's default environment plus
        // TERM_PROGRAM so the shell-integration script can detect Sidekick.
        var environment = Terminal.getEnvironmentVariables()
        environment.append("TERM_PROGRAM=\(ShellIntegration.termProgram)")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            environment.append("TERM_PROGRAM_VERSION=\(version)")
        }
        terminalView.startProcess(
            executable: shell,
            environment: environment,
            execName: shellIdiom,
            currentDirectory: startDirectory
        )

        // Publish the initial title/CWD once the process is up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.currentCWD = startDirectory
            self?.updateTitle()
        }
    }

    // Returns the shell associated with the current account
    private func getShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/bash"
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer {
            buffer.deallocate()
        }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = UnsafeMutablePointer<passwd>.allocate(capacity: 1)

        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 {
            return "/bin/bash"
        }
        return String(cString: pwd.pw_shell)
    }

    private func startCWDTracking() {
        cwdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateCWD()
        }
    }

    private func updateCWD() {
        guard shellPID > 0 else { return }
        guard !isUpdatingCWD else { return }

        isUpdatingCWD = true
        let pid = shellPID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cwd = CWDDetector.getCWD(for: pid)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isUpdatingCWD = false

                // Only refresh the title (which spawns git for the branch)
                // when the directory actually changed.
                if let cwd = cwd, cwd != self.currentCWD {
                    self.currentCWD = cwd
                    self.updateTitle()
                }
            }
        }
    }

    private func updateTitle() {
        let cwdURL = URL(fileURLWithPath: currentCWD)
        let basename = cwdURL.lastPathComponent.isEmpty ? "~" : cwdURL.lastPathComponent

        DispatchQueue.global(qos: .background).async { [weak self] in
            let branch = self?.getGitBranch(at: self?.currentCWD ?? "")

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Update window title
                if let branch = branch, !branch.isEmpty {
                    self.view.window?.title = "\(basename) (\(branch)) - Sidekick"
                } else {
                    self.view.window?.title = "\(basename) - Sidekick"
                }

                // Notify delegate for tab title updates
                self.delegate?.terminalDidUpdateTitle(self, directory: self.currentCWD, branch: branch)
            }
        }
    }

    private func getGitBranch(at path: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", path, "symbolic-ref", "--short", "HEAD"]
        task.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return output?.isEmpty == false ? output : nil
            } else {
                // Try alternative method for detached HEAD
                return getGitBranchDetached(at: path)
            }
        } catch {
            return nil
        }
    }

    private func getGitBranchDetached(at path: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", path, "rev-parse", "--short", "HEAD"]
        task.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    return "detached@\(output)"
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private func handleProcessTerminated() {
        cwdTimer?.invalidate()
        cwdTimer = nil
        resetAgentState()
    }

    // MARK: - LocalProcessTerminalViewDelegate Methods

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal has been resized - SwiftTerm handles this automatically
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Don't update the window title - we use tab titles instead
        // The window title stays as "Sidekick"
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 command received - update current directory
        // The directory comes as a file:// URL, convert to path
        guard let directory = directory else { return }

        let newCWD: String
        if let url = URL(string: directory), url.scheme == "file" {
            newCWD = url.path
        } else if directory.hasPrefix("file://") {
            // Shell integration emits the path unencoded; URL parsing fails
            // for paths with spaces, so strip the scheme and host manually.
            let afterScheme = directory.dropFirst("file://".count)
            if let firstSlash = afterScheme.firstIndex(of: "/") {
                newCWD = String(afterScheme[firstSlash...])
            } else {
                return
            }
        } else {
            newCWD = directory
        }

        // The shell is reporting its own directory — polling is redundant.
        markShellIntegrationDetected()

        if newCWD != currentCWD {
            currentCWD = newCWD
            updateTitle()
        }
    }

    /// Once the shell proves it has integration (OSC 7 or OSC 133), stop
    /// the CWD polling timer — updates now arrive for free.
    private func markShellIntegrationDetected() {
        guard !hasShellIntegration else { return }
        hasShellIntegration = true
        cwdTimer?.invalidate()
        cwdTimer = nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        handleProcessTerminated()
        if let exitCode = exitCode {
            print("Shell process terminated with exit code: \(exitCode)")
        } else {
            print("Shell process vanished unexpectedly")
        }
    }

    private func setupURLHandling() {
        // URL handling will be implemented later when SwiftTerm provides public APIs for text access
        // For now, users can copy URLs manually and open them
    }

    private func queueAgentDetection(_ output: String) {
        // Coalesce high-throughput output into ~10Hz detection passes so the
        // regex scanning doesn't run once per output chunk.
        pendingDetectionOutput += output
        if pendingDetectionOutput.count > 16_000 {
            pendingDetectionOutput = String(pendingDetectionOutput.suffix(16_000))
        }

        guard !detectionFlushScheduled else { return }
        detectionFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.detectionFlushScheduled = false
            let chunk = self.pendingDetectionOutput
            self.pendingDetectionOutput = ""
            guard !chunk.isEmpty else { return }
            self.detectAgentState(from: chunk)
        }
    }

    private func detectAgentState(from output: String) {
        consumeCommandMarkSequences(from: output)
        detectDevServer(in: output)

        if consumeAgentStatusSequences(from: output) {
            return
        }

        recentOutput += output
        if recentOutput.count > 8_000 {
            recentOutput = String(recentOutput.suffix(8_000))
        }

        let normalizedRecentOutput = normalizeTerminalOutput(recentOutput)
        let normalizedCurrentOutput = normalizeTerminalOutput(output)

        if containsAgentPrompt(normalizedRecentOutput) {
            agentDoneTimer?.invalidate()
            agentDoneTimer = nil
            notifyDetectedAgentState(.ready)
        } else if hasExplicitAgentStatus {
            // Working/done come from the agent's hooks; guessing them from
            // output here would fabricate "done" (quiet period) while a
            // permission dialog is still waiting for the user.
        } else if containsAgentWorkingCue(normalizedCurrentOutput) {
            notifyDetectedAgentState(.working)
            scheduleDoneAfterQuietPeriod()
        } else if lastDetectedAgentState == .working {
            scheduleDoneAfterQuietPeriod()
        }
    }

    // MARK: - Cmd+click file opening

    private static let filePathTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "((?:~|\\.{1,2})?/?[A-Za-z0-9_@+.\\-]+(?:/[A-Za-z0-9_@+.\\-]+)*)(?::(\\d+))?"
    )

    /// Cmd+click: if the clicked cell sits on a file path (optionally with
    /// `:line`), open it in the built-in editor. Returns true when handled.
    private func handleCommandClick(col: Int, row: Int) -> Bool {
        guard let line = terminalView.getTerminal().getLine(row: row) else { return false }
        let text = line.translateToString(trimRight: true)
        guard !text.isEmpty else { return false }

        guard let regex = Self.filePathTokenRegex else { return false }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            // The clicked column must fall inside this token.
            guard match.range.location <= col, col < match.range.location + match.range.length else { continue }

            let candidate = nsText.substring(with: match.range(at: 1))
            var lineNumber: Int?
            if match.range(at: 2).location != NSNotFound {
                lineNumber = Int(nsText.substring(with: match.range(at: 2)))
            }

            // Require something path-like, not a bare word.
            guard candidate.contains("/") || candidate.contains(".") else { continue }

            guard let resolved = resolveFilePath(candidate) else { continue }
            delegate?.terminalRequestsOpenFile(self, path: resolved, line: lineNumber)
            return true
        }
        return false
    }

    private func resolveFilePath(_ candidate: String) -> String? {
        let expanded: String
        if candidate.hasPrefix("~") {
            expanded = NSString(string: candidate).expandingTildeInPath
        } else if candidate.hasPrefix("/") {
            expanded = candidate
        } else {
            expanded = URL(fileURLWithPath: currentCWD).appendingPathComponent(candidate).path
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    // MARK: - Dev-server detection

    private func detectDevServer(in output: String) {
        // Strip ANSI codes but keep case (URLs paths are case-sensitive).
        var text = output
        if let ansiRegex = Self.ansiEscapeRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = ansiRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        var url: URL?
        if let regex = Self.serverURLRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let matchRange = Range(match.range, in: text) {
                url = URL(string: normalizeLocalURLString(String(text[matchRange])))
            }
        }
        if url == nil, let regex = Self.listeningPortRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let portRange = Range(match.range(at: 1), in: text),
               let port = Int(text[portRange]), port >= 80 {
                url = URL(string: "http://localhost:\(port)/")
            }
        }

        guard let serverURL = url, serverURL != lastOfferedServerURL else { return }
        lastOfferedServerURL = serverURL
        showServerBanner(for: serverURL)
    }

    private func normalizeLocalURLString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "0.0.0.0", with: "localhost")
            .replacingOccurrences(of: "127.0.0.1", with: "localhost")
    }

    private func showServerBanner(for url: URL) {
        hideServerBanner()
        detectedServerURL = url

        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(hex: "#313244")?.cgColor
        banner.layer?.cornerRadius = 6
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = NSColor(hex: "#45475a")?.cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false

        let host = url.host ?? "localhost"
        let port = url.port.map { ":\($0)" } ?? ""
        let openButton = NSButton(
            title: "Open \(host)\(port) in browser",
            target: self,
            action: #selector(serverBannerOpenClicked)
        )
        openButton.bezelStyle = .inline
        openButton.isBordered = false
        openButton.contentTintColor = NSColor(hex: "#89b4fa")
        openButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(
            title: "✕",
            target: self,
            action: #selector(serverBannerDismissClicked)
        )
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(hex: "#6c7086")
        closeButton.font = NSFont.systemFont(ofSize: 11)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(openButton)
        banner.addSubview(closeButton)
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            banner.heightAnchor.constraint(equalToConstant: 30),

            openButton.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            openButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])

        serverBannerView = banner

        let dismissWork = DispatchWorkItem { [weak self] in
            self?.hideServerBanner()
        }
        serverBannerDismissWork = dismissWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: dismissWork)
    }

    private func hideServerBanner() {
        serverBannerDismissWork?.cancel()
        serverBannerDismissWork = nil
        serverBannerView?.removeFromSuperview()
        serverBannerView = nil
    }

    @objc private func serverBannerOpenClicked() {
        if let url = detectedServerURL {
            delegate?.terminalRequestsOpenURL(self, url: url)
        }
        hideServerBanner()
    }

    @objc private func serverBannerDismissClicked() {
        hideServerBanner()
    }

    // MARK: - Shell integration (OSC 133 command marks)

    private func consumeCommandMarkSequences(from output: String) {
        commandMarkBuffer += output
        if commandMarkBuffer.count > 2_000 {
            commandMarkBuffer = String(commandMarkBuffer.suffix(2_000))
        }

        guard let regex = Self.commandMarkRegex else { return }

        let searchRange = NSRange(commandMarkBuffer.startIndex..<commandMarkBuffer.endIndex, in: commandMarkBuffer)
        let matches = regex.matches(in: commandMarkBuffer, range: searchRange)
        guard !matches.isEmpty else { return }

        var consumedUpperBound = commandMarkBuffer.startIndex
        for match in matches {
            if let matchRange = Range(match.range, in: commandMarkBuffer) {
                consumedUpperBound = matchRange.upperBound
            }
            guard let kindRange = Range(match.range(at: 1), in: commandMarkBuffer) else { continue }
            let kind = String(commandMarkBuffer[kindRange])
            var parameter: String?
            if match.range(at: 2).location != NSNotFound,
               let parameterRange = Range(match.range(at: 2), in: commandMarkBuffer) {
                parameter = String(commandMarkBuffer[parameterRange])
            }
            handleCommandMark(kind: kind, parameter: parameter)
        }
        commandMarkBuffer = String(commandMarkBuffer[consumedUpperBound...])
    }

    private func handleCommandMark(kind: String, parameter: String?) {
        markShellIntegrationDetected()

        switch kind {
        case "A":
            // Prompt drawn — remember where, for jump-to-prompt navigation.
            if let row = absoluteCursorRow() {
                promptMarkRows.append(row)
                if promptMarkRows.count > Self.maxPromptMarks {
                    promptMarkRows.removeFirst(promptMarkRows.count - Self.maxPromptMarks)
                }
            }
        case "C":
            // Command started — clear the previous command's status.
            commandStartDate = Date()
            delegate?.terminalDidUpdateCommandStatus(self, status: nil)
        case "D":
            let exitCode = parameter.flatMap { Int($0) } ?? 0
            let duration = commandStartDate.map { Date().timeIntervalSince($0) }
            commandStartDate = nil
            delegate?.terminalDidUpdateCommandStatus(
                self,
                status: TerminalCommandStatus(exitCode: exitCode, duration: duration)
            )
            // The foreground command exited and the shell is back at its
            // prompt — whatever agent was running here (Ctrl+C'd, quit, or
            // crashed) is gone, so drop the tab from the agents panel.
            resetAgentState()
        default:
            break
        }
    }

    /// The cursor's absolute row in the scrollback buffer, derived from
    /// public SwiftTerm API (yBase itself is not exposed).
    private func absoluteCursorRow() -> Int? {
        let buffer = terminalView.getTerminal().buffer

        // Pinned at the bottom (or no scrollback yet): yDisp == yBase.
        if !terminalView.canScroll || terminalView.scrollPosition >= 1.0 {
            return buffer.yDisp + buffer.y
        }

        // Scrolled up: recover yBase from scrollPosition = yDisp / maxScrollback.
        let position = terminalView.scrollPosition
        guard position > 0, buffer.yDisp > 0 else { return nil }
        let yBase = Int((Double(buffer.yDisp) / position).rounded())
        return yBase + buffer.y
    }

    /// Scrolls so the most recent prompt above the current view lands at the top.
    func scrollToPreviousPrompt() {
        let currentTop = terminalView.getTerminal().buffer.yDisp
        guard let target = promptMarkRows.last(where: { $0 < currentTop }) else {
            terminalView.scrollUp(lines: terminalView.getTerminal().rows)
            return
        }
        terminalView.scrollUp(lines: currentTop - target)
    }

    /// Scrolls so the next prompt below the current view lands at the top.
    func scrollToNextPrompt() {
        let currentTop = terminalView.getTerminal().buffer.yDisp
        guard let target = promptMarkRows.first(where: { $0 > currentTop }) else {
            terminalView.scrollDown(lines: terminalView.getTerminal().rows)
            return
        }
        terminalView.scrollDown(lines: target - currentTop)
    }

    private func consumeAgentStatusSequences(from output: String) -> Bool {
        agentStatusSequenceBuffer += output
        if agentStatusSequenceBuffer.count > 2_000 {
            agentStatusSequenceBuffer = String(agentStatusSequenceBuffer.suffix(2_000))
        }

        guard let regex = Self.agentStatusRegex else {
            return false
        }

        let searchRange = NSRange(agentStatusSequenceBuffer.startIndex..<agentStatusSequenceBuffer.endIndex, in: agentStatusSequenceBuffer)
        let matches = regex.matches(in: agentStatusSequenceBuffer, range: searchRange)
        guard !matches.isEmpty else {
            return false
        }

        var consumedUpperBound = agentStatusSequenceBuffer.startIndex
        for match in matches {
            if let matchRange = Range(match.range, in: agentStatusSequenceBuffer) {
                consumedUpperBound = matchRange.upperBound
            }
            guard let statusRange = Range(match.range(at: 1), in: agentStatusSequenceBuffer),
                  let state = agentState(fromStatus: String(agentStatusSequenceBuffer[statusRange])) else {
                continue
            }
            applyExplicitAgentState(state)
        }

        agentStatusSequenceBuffer = String(agentStatusSequenceBuffer[consumedUpperBound...])
        return true
    }

    private func agentState(fromStatus status: String) -> AgentState? {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "busy", "working", "running":
            return .working
        case "ready", "prompt", "waiting", "needs-user", "needs_user":
            return .ready
        case "done", "finished", "complete":
            return .done
        case "idle", "clear", "reset":
            return .idle
        default:
            return nil
        }
    }

    /// Returns agent tracking to a clean slate (state idle, heuristics
    /// re-armed) once the agent process is known to be gone.
    private func resetAgentState() {
        guard lastDetectedAgentState != .idle else { return }
        hasExplicitAgentStatus = false
        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil
        notifyDetectedAgentState(.idle)
    }

    private func applyExplicitAgentState(_ state: AgentState) {
        hasExplicitAgentStatus = true
        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil
        notifyDetectedAgentState(state)
    }

    private func normalizeTerminalOutput(_ output: String) -> String {
        guard let regex = Self.ansiEscapeRegex else { return output.lowercased() }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
            .lowercased()
    }

    private func containsAgentPrompt(_ output: String) -> Bool {
        return output.contains("do you want to proceed?")
            || output.contains("do you want to continue?")
            || output.contains("esc to cancel")
            || output.contains("tab to add additional instructions")
            || output.contains("don't ask again")
    }

    private func containsAgentWorkingCue(_ output: String) -> Bool {
        return output.contains("running...")
            || output.contains("running…")
            || output.contains("thinking")
            || output.contains("working")
    }

    private func handleTerminalInput() {
        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil

        if hasExplicitAgentStatus {
            // Answering a dialog resumes work (the prompt-detection above
            // restores .ready if the dialog merely redrew), but "done" only
            // ever comes from the agent's Stop hook — and typing a new
            // prompt stays "done" until UserPromptSubmit reports busy.
            if lastDetectedAgentState == .ready {
                notifyDetectedAgentState(.working)
            }
            return
        }

        if lastDetectedAgentState == .ready || lastDetectedAgentState == .done {
            notifyDetectedAgentState(.working)
            scheduleDoneAfterQuietPeriod()
        }
    }

    private func scheduleDoneAfterQuietPeriod() {
        agentDoneTimer?.invalidate()
        agentDoneTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self = self, self.lastDetectedAgentState == .working else { return }
            self.notifyDetectedAgentState(.done)
        }
    }

    private func notifyDetectedAgentState(_ state: AgentState) {
        guard state != lastDetectedAgentState else { return }
        lastDetectedAgentState = state

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.terminalDidDetectAgentState(self, state: state)
        }
    }

    func getCurrentWorkingDirectory() -> String {
        return currentCWD
    }

    // MARK: - Copy/Paste Support
    // SwiftTerm's LocalProcessTerminalView already handles copy/paste through the responder chain
    // These methods ensure the terminal view receives the copy/paste commands

    @objc func copy(_ sender: Any?) {
        terminalView.copy(sender as Any)
    }

    @objc func paste(_ sender: Any?) {
        terminalView.paste(sender as Any)
    }

    func send(text: String) {
        // Send text to the terminal
        terminalView.send(txt: text)
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalView)
    }

    /// True when keyboard input is actually going to this terminal (not an
    /// editor, browser, find bar, or sidebar field).
    var isTerminalFocused: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === terminalView || responder.isDescendant(of: terminalView)
    }

    // MARK: - Scrollback search

    func showFindBar() {
        if findBar == nil {
            let bar = TerminalFindBar()
            bar.delegate = self
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
            ])
            findBar = bar
        }
        findBar?.isHidden = false
        findBar?.focusSearchField()
    }

    func hideFindBar() {
        guard let findBar = findBar, !findBar.isHidden else { return }
        findBar.isHidden = true
        terminalView.clearSearch()
        focusTerminal()
    }

    func applyConfig(_ newConfig: Config) {
        print("🔄 Applying config to terminal: font=\(newConfig.font.family) size=\(newConfig.font.size) blur=\(newConfig.window.enableBlur)")
        self.config = newConfig

        // Update font (respecting the current app-wide zoom)
        terminalView.font = terminalFont(for: newConfig)

        applyTerminalAppearance(newConfig)

        // Force terminal to refresh
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    private func applyTerminalAppearance(_ config: Config) {
        let baseColor = NSColor(hex: "#1e1e2e")!

        if config.window.enableBlur {
            let alpha = CGFloat(max(0.0, min(1.0, config.window.opacity)))
            print("🎨 Setting terminal background alpha to \(alpha)")
            let backgroundColor = baseColor.withAlphaComponent(alpha)
            view.layer?.backgroundColor = backgroundColor.cgColor
            view.layer?.isOpaque = false
            terminalView.nativeBackgroundColor = .clear
            terminalView.layer?.backgroundColor = NSColor.clear.cgColor
            terminalView.layer?.isOpaque = false
            terminalView.alphaValue = 1.0
        } else {
            view.layer?.backgroundColor = baseColor.cgColor
            view.layer?.isOpaque = true
            terminalView.nativeBackgroundColor = baseColor
            terminalView.layer?.backgroundColor = baseColor.cgColor
            terminalView.layer?.isOpaque = true
            terminalView.alphaValue = 1.0
        }
    }

    deinit {
        MainActor.assumeIsolated {
            cwdTimer?.invalidate()
            agentDoneTimer?.invalidate()
            if let scrollEventMonitor {
                NSEvent.removeMonitor(scrollEventMonitor)
            }
        }
    }
}

extension TerminalViewController: TerminalFindBarDelegate {
    func findBar(_ bar: TerminalFindBar, searchChanged term: String) {
        terminalView.clearSearch()
        guard !term.isEmpty else { return }
        terminalView.findNext(term)
    }

    func findBar(_ bar: TerminalFindBar, findNext term: String) {
        terminalView.findNext(term)
    }

    func findBar(_ bar: TerminalFindBar, findPrevious term: String) {
        terminalView.findPrevious(term)
    }

    func findBarDidClose(_ bar: TerminalFindBar) {
        hideFindBar()
    }
}
