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

/// A finished shell command captured from OSC 133 marks: the command line
/// (carried base64-encoded in the `C` mark by the shell integration), its exit
/// code and duration (from the `D` mark), and the ANSI-stripped output printed
/// between the two marks. Output framing is approximate at the ~100ms
/// detection-coalescing boundary, which is fine for agent legibility.
struct TerminalCommandRecord {
    let command: String
    let exitCode: Int
    let duration: TimeInterval?
    let output: String
    let finishedAt: Date
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
        // Focus and mouse reports are emitted by the emulator itself when the
        // view is focused, clicked, or hovered — the user didn't type them, so
        // they must not count as "the user is working" (that flipped a finished
        // agent back to Working whenever its tab was activated).
        if !Self.isTerminalGeneratedReport(data) {
            onInput?()
        }
        super.send(source: source, data: data)
    }

    /// True when `data` is purely a focus-tracking (CSI I / CSI O) or
    /// mouse-report (CSI M… / CSI <…) sequence the terminal generated on its
    /// own, rather than a genuine keystroke or paste.
    private static func isTerminalGeneratedReport(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 3 else { return false }
        let bytes = Array(data)
        guard bytes[0] == 0x1B, bytes[1] == 0x5B else { return false } // ESC [
        switch bytes[2] {
        case 0x49, 0x4F:          // CSI I / CSI O — focus in / focus out
            return bytes.count == 3
        case 0x4D, 0x3C:          // CSI M / CSI < — mouse report (X10 / SGR)
            return true
        default:
            return false
        }
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
    private let paneID: UUID
    private let initialCommand: [String]?
    private var recentOutput = ""
    private var agentStatusSequenceBuffer = ""
    private var lastDetectedAgentState: AgentState = .idle
    // Once the session reports state via OSC 666 (Claude/Codex hooks), those
    // reports are authoritative and the text heuristics stand down.
    private var hasExplicitAgentStatus = false
    private var agentDoneTimer: Timer?
    private var blockedPollingTimer: Timer?
    private var suppressedPromptMarkers: Set<String> = []
    private var pendingDetectionOutput = ""
    private var detectionFlushScheduled = false
    private var automationOutput = ""

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

    // Per-command record capture (OSC 133 C..D windows), surfaced by
    // `sidekick-ctl pane read --json` for agent-legible command history.
    private struct InFlightCommand {
        let command: String
        let startDate: Date
        var output: String = ""
    }
    private var inFlightCommand: InFlightCommand?
    private var commandRecords: [TerminalCommandRecord] = []
    private static let maxCommandRecords = 100
    /// Raw output captured per command is bounded so a runaway log tail can't
    /// grow this pane's memory without limit; the tail is what agents read.
    private static let maxCommandOutputChars = 256_000

    private static let commandMarkRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\]133;([A-Za-z])(?:;([^\u{001B}\u{0007}]*))?(?:\u{001B}\\\\|\u{0007})")

    private static let agentStatusRegex: NSRegularExpression? = {
        let escapedTermprop = NSRegularExpression.escapedPattern(for: agentStatusTermprop)
        let pattern = "\u{001B}\\]666;\(escapedTermprop)=([A-Za-z_-]+)(?:\u{001B}\\\\|\u{0007})"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let ansiEscapeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")

    /// OSC sequences (ESC ] … BEL/ST) — cwd reports, title sets, and our own
    /// 7/133/666 marks. Stripped from command records so the captured output
    /// is the command's actual text, not control chatter.
    private static let oscEscapeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)")

    init(
        config: Config,
        initialDirectory: String? = nil,
        paneID: UUID = UUID(),
        command: [String]? = nil
    ) {
        self.config = config
        self.initialDirectory = initialDirectory
        self.paneID = paneID
        self.initialCommand = command?.isEmpty == false ? command : nil
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
        startConfiguredProcess()
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
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            guard let self = self else { return event }
            switch event.type {
            case .leftMouseDragged:
                self.sawLeftMouseDrag = true
                return event
            case .leftMouseUp:
                return self.handleTerminalMouseUp(event)
            default:
                return self.handleScrollWheelEvent(event)
            }
        }
    }

    /// Tracks whether the in-flight left-button gesture involved a drag — a
    /// drag is a text selection and must never be treated as a link click.
    private var sawLeftMouseDrag = false

    /// Owns link/file activation over the terminal. ⌘+click opens file paths
    /// in the built-in editor and URLs in the browser pane. When the release
    /// lands on a link/file the event is swallowed so SwiftTerm's own handler
    /// can't ALSO open it — that handler opens links in the *external* browser
    /// (NSWorkspace.open) and fired even on stray clicks that SwiftTerm
    /// resolved to a URL, which is what made links open seemingly on hover.
    private func handleTerminalMouseUp(_ event: NSEvent) -> NSEvent? {
        let wasDrag = sawLeftMouseDrag
        sawLeftMouseDrag = false

        guard let window = view.window,
              event.window === window,
              let terminalView = terminalView,
              // Hidden tabs share window coordinates with the visible one;
              // without this, an invisible terminal swallows the click.
              !terminalView.isHiddenOrHasHiddenAncestor else { return event }

        let pointInView = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(pointInView) else { return event }

        // A drag is a selection — let SwiftTerm finish it normally.
        guard !wasDrag else { return event }

        let terminal = terminalView.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return event }

        let cellWidth = max(1, terminalView.bounds.width / CGFloat(terminal.cols))
        let cellHeight = max(1, terminalView.bounds.height / CGFloat(terminal.rows))
        let col = min(terminal.cols - 1, max(0, Int(pointInView.x / cellWidth)))
        let row = min(terminal.rows - 1, max(0, Int((terminalView.bounds.height - pointInView.y) / cellHeight)))

        let hasCommand = event.modifierFlags.contains(.command)

        if hasCommand, handleCommandClick(col: col, row: row) {
            return nil
        }
        if let url = urlUnderClick(col: col, row: row) {
            // Only a deliberate ⌘+click opens the link; a plain click is
            // swallowed so the link never opens on its own.
            if hasCommand {
                delegate?.terminalRequestsOpenURL(self, url: url)
            }
            return nil
        }
        // Not on a link/file: let SwiftTerm handle the click normally.
        return event
    }

    private func urlUnderClick(col: Int, row: Int) -> URL? {
        // Ask SwiftTerm for the link at this cell: it spans wrapped rows (so a
        // URL broken across lines is returned whole, not just the clicked
        // fragment) and understands OSC 8 hyperlinks.
        guard var candidate = terminalView.getTerminal().link(
            at: .screen(Position(col: col, row: row)),
            mode: .explicitAndImplicit
        ), !candidate.isEmpty else { return nil }

        // Trim punctuation that commonly trails URLs in prose.
        while let last = candidate.last, ".,;:!?".contains(last) {
            candidate.removeLast()
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
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

        Log.debug("🔤 Terminal font: \(font.fontName) size: \(font.pointSize)", category: "terminal")

        let agentAwareTerminalView = AgentAwareTerminalView(frame: view.bounds)
        agentAwareTerminalView.onOutput = { [weak self] output in
            DispatchQueue.main.async {
                self?.appendAutomationOutput(output)
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
        applyThemeColors()

        // Apply background based on blur configuration
        terminalView.wantsLayer = true
        applyTerminalAppearance(config)

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

    private func startConfiguredProcess() {
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
        environment.append("SIDEKICK_ENV=1")
        environment.append("SIDEKICK_PANE_ID=\(paneID.uuidString.lowercased())")
        environment.append("SIDEKICK_SOCKET_PATH=\(Self.socketPath)")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            environment.append("TERM_PROGRAM_VERSION=\(version)")
        }
        if let command = initialCommand {
            // Launch the worker through the user's login+interactive shell so
            // it inherits the same PATH and version-manager setup a normal pane
            // gets (e.g. ~/.local/bin, nvm). The command string is the fixed
            // literal `exec "$@"`; the requested argv arrives as positional
            // parameters, so the shell never re-parses it — no interpolation or
            // command-injection. `exec` replaces the shell so the worker is the
            // pane's root process and its exit transitions the pane to .done.
            terminalView.startProcess(
                executable: shell,
                args: ["-i", "-c", "exec \"$@\"", shellIdiom] + command,
                environment: environment,
                execName: shellIdiom,
                currentDirectory: startDirectory
            )
        } else {
            terminalView.startProcess(
                executable: shell,
                environment: environment,
                execName: shellIdiom,
                currentDirectory: startDirectory
            )
        }

        // Publish the initial title/CWD once the process is up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.currentCWD = startDirectory
            self?.updateTitle()
        }
    }

    private static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sidekick/sidekick.sock").path
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
        if initialCommand != nil {
            // A directly launched worker has no parent shell to return to.
            // Keep the finished pane actionable for waiters and the dashboard.
            notifyDetectedAgentState(.done)
        } else {
            resetAgentState()
        }
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

    private func appendAutomationOutput(_ output: String) {
        automationOutput += output
        if automationOutput.count > 64_000 {
            automationOutput = String(automationOutput.suffix(64_000))
        }

        if !outputMatchers.isEmpty {
            feedOutputMatchers(strippedChunk: stripANSIEscapes(output))
        }

        // While a command is running (between OSC 133 C and D), accumulate its
        // output for the command-record history. ANSI is stripped at finalize.
        if inFlightCommand != nil {
            inFlightCommand!.output += output
            if inFlightCommand!.output.count > Self.maxCommandOutputChars {
                inFlightCommand!.output = String(inFlightCommand!.output.suffix(Self.maxCommandOutputChars))
            }
        }
    }

    private func detectAgentState(from output: String) {
        consumeCommandMarkSequences(from: output)
        detectDevServer(in: output)

        if consumeAgentStatusSequences(from: output) {
            return
        }

        // Once any OSC 666 has arrived this pane is hook-authoritative: the
        // agent reports busy/ready/done/idle itself, so the text heuristics
        // below stand down entirely. Running them alongside the hooks only
        // fabricates transitions the agent never reported — the root of the
        // "stuck on Working" / Working↔NeedsInput-flicker races. Heuristics
        // remain for un-hooked sessions (a plain shell, or an agent whose
        // integration isn't installed), and resume if the agent process exits
        // (resetAgentState clears hasExplicitAgentStatus).
        if hasExplicitAgentStatus { return }

        recentOutput += output
        if recentOutput.count > 8_000 {
            recentOutput = String(recentOutput.suffix(8_000))
        }

        let normalizedRecentOutput = normalizeTerminalOutput(recentOutput)
        let normalizedCurrentOutput = normalizeTerminalOutput(output)
        let actionablePromptMarkers = agentPromptMarkers(in: normalizedRecentOutput)
            .subtracting(suppressedPromptMarkers)

        if !actionablePromptMarkers.isEmpty {
            agentDoneTimer?.invalidate()
            agentDoneTimer = nil
            notifyDetectedAgentState(.ready)
        } else if containsAgentWorkingCue(normalizedCurrentOutput),
                  lastDetectedAgentState != .ready {
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
        banner.layer?.backgroundColor = Theme.shared.palette.surface0.cgColor
        banner.layer?.cornerRadius = 6
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = Theme.shared.palette.surface1.cgColor
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
        openButton.contentTintColor = AppTheme.accent
        openButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(
            title: "✕",
            target: self,
            action: #selector(serverBannerDismissClicked)
        )
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = AppTheme.mutedText
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
            // Command started — clear the previous command's status and begin
            // capturing a new record. The shell integration carries the command
            // line base64-encoded in the C parameter (`133;C;<base64>`).
            let started = Date()
            commandStartDate = started
            inFlightCommand = InFlightCommand(command: Self.decodeCommandParameter(parameter), startDate: started)
            delegate?.terminalDidUpdateCommandStatus(self, status: nil)
        case "D":
            let exitCode = parameter.flatMap { Int($0) } ?? 0
            let duration = commandStartDate.map { Date().timeIntervalSince($0) }
            commandStartDate = nil
            finalizeCommandRecord(exitCode: exitCode, duration: duration)
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

    /// Decodes the base64 command line carried in the OSC 133 `C` parameter.
    /// Returns "" when absent (a shell whose integration predates this, or a
    /// command with no captured line) so a record is still produced.
    private static func decodeCommandParameter(_ parameter: String?) -> String {
        guard let parameter, !parameter.isEmpty,
              let data = Data(base64Encoded: parameter),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalizeCommandRecord(exitCode: Int, duration: TimeInterval?) {
        guard let inFlight = inFlightCommand else { return }
        inFlightCommand = nil

        let cleanOutput = stripANSIEscapes(stripOSCSequences(inFlight.output))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        commandRecords.append(TerminalCommandRecord(
            command: inFlight.command,
            exitCode: exitCode,
            duration: duration,
            output: cleanOutput,
            finishedAt: Date()
        ))
        if commandRecords.count > Self.maxCommandRecords {
            commandRecords.removeFirst(commandRecords.count - Self.maxCommandRecords)
        }
    }

    /// The most recently finished commands (oldest first), capped to `limit`
    /// when given. Surfaced over IPC for `sidekick-ctl pane read --json`.
    func recentCommandRecords(limit: Int? = nil) -> [TerminalCommandRecord] {
        guard let limit, limit > 0 else { return commandRecords }
        return Array(commandRecords.suffix(limit))
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
        stopBlockedPolling()
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
        stripANSIEscapes(output).lowercased()
    }

    private func stripANSIEscapes(_ output: String) -> String {
        guard let regex = Self.ansiEscapeRegex else { return output }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    private func stripOSCSequences(_ output: String) -> String {
        guard let regex = Self.oscEscapeRegex else { return output }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    private func agentPromptMarkers(in output: String) -> Set<String> {
        // Claude Code — specific dialog/prompt phrases only.
        // "esc to cancel" alone is intentionally excluded: it appears in the
        // normal running-spinner footer ("Running... (esc to cancel)") and
        // causes constant Working↔NeedsInput flicker when the poller reads it.
        // "tab to add additional instructions" is also excluded: it is the
        // normal input footer Claude renders after Stop, not a request that is
        // blocking an active run.
        let markers = [
            "do you want to proceed?",
            "do you want to continue?",
            "don't ask again",
            // Codex
            "allow command?",
            "press enter to confirm or esc to cancel",
            "enter to submit answer",
            "enter to submit all"
        ]
        return Set(markers.filter { output.contains($0) })
    }

    private func containsAgentWorkingCue(_ output: String) -> Bool {
        return output.contains("running...")
            || output.contains("running…")
            || output.contains("thinking")
            || output.contains("working")
    }

    private func handleTerminalInput() {
        // Hook-equipped agents report every transition over OSC 666, so input
        // must never move agent state: Working comes from UserPromptSubmit /
        // PreToolUse, Ready from Notification, Done from Stop. Guessing from
        // keystrokes is what stranded finished agents on "Working" once their
        // pane was focused. (Focus/mouse reports are already filtered upstream,
        // but real keystrokes are silenced here too — the next hook is
        // authoritative and effectively instant.)
        if hasExplicitAgentStatus { return }

        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil

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
        let previousState = lastDetectedAgentState
        lastDetectedAgentState = state

        // Blocked-polling scrapes the visible screen for permission dialogs —
        // a heuristic only needed when no hook reports .ready. Hook-authoritative
        // panes get .ready from the Notification hook, so skip the scraping.
        if state == .working && !hasExplicitAgentStatus {
            startBlockedPolling(suppressingVisiblePrompt: previousState == .ready)
        } else {
            stopBlockedPolling()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.terminalDidDetectAgentState(self, state: state)
        }
    }

    // MARK: - Blocked-state polling

    // Polls the visible screen content while the agent is working so we can
    // detect permission dialogs even when no new PTY data arrives after the UI
    // renders (the OSC hook fires before the dialog, then data stops flowing).
    private func startBlockedPolling(suppressingVisiblePrompt: Bool) {
        stopBlockedPolling()
        if suppressingVisiblePrompt {
            let screen = normalizeTerminalOutput(readVisibleScreenText())
            suppressedPromptMarkers = agentPromptMarkers(in: screen)
        }
        blockedPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollForBlockedState()
        }
    }

    private func stopBlockedPolling() {
        blockedPollingTimer?.invalidate()
        blockedPollingTimer = nil
        suppressedPromptMarkers.removeAll()
    }

    private func pollForBlockedState() {
        guard lastDetectedAgentState == .working else {
            stopBlockedPolling()
            return
        }
        let screen = readVisibleScreenText()
        let normalized = normalizeTerminalOutput(screen)
        let visibleMarkers = agentPromptMarkers(in: normalized)

        // When a user answers a permission dialog, its text can remain in the
        // terminal for another redraw. Ignore those same markers until they
        // disappear; otherwise polling changes ready -> working -> ready using
        // stale cells from the dialog that was just answered.
        suppressedPromptMarkers.formIntersection(visibleMarkers)
        if !visibleMarkers.subtracting(suppressedPromptMarkers).isEmpty {
            agentDoneTimer?.invalidate()
            agentDoneTimer = nil
            notifyDetectedAgentState(.ready)
        }
    }

    private func readVisibleScreenText() -> String {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        // Interactive dialogs live at the bottom. Restricting the scan keeps a
        // prompt higher in the viewport's scrollback from looking current.
        let firstRow = max(0, terminal.rows - 12)
        for row in firstRow..<terminal.rows {
            if let line = terminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        return lines.joined(separator: "\n")
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

    @discardableResult
    func send(key: String) -> Bool {
        let sequence: String
        switch key.lowercased() {
        case "enter", "return": sequence = "\r"
        case "tab": sequence = "\t"
        case "escape", "esc": sequence = "\u{1B}"
        case "backspace": sequence = "\u{7F}"
        case "ctrl-c", "control-c": sequence = "\u{03}"
        case "ctrl-d", "control-d": sequence = "\u{04}"
        case "up": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
        case "down": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
        case "right": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OC" : "\u{1B}[C"
        case "left": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OD" : "\u{1B}[D"
        default: return false
        }
        terminalView.send(txt: sequence)
        return true
    }

    var shellProcessID: pid_t {
        shellPID
    }

    func visibleScreenText(lineLimit: Int? = nil) -> String {
        let text = readVisibleScreenText()
        guard let lineLimit, lineLimit > 0 else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lineLimit)
            .joined(separator: "\n")
    }

    func recentOutputText(lineLimit: Int? = nil) -> String {
        let text = stripANSIEscapes(automationOutput)
        guard let lineLimit, lineLimit > 0 else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lineLimit)
            .joined(separator: "\n")
    }

    // MARK: - Streaming output match (for `wait output`)

    /// A pending `wait output` request: an incremental matcher plus the callback
    /// to fire when it hits.
    private struct OutputMatcher {
        var matcher: StreamingMatcher
        let onMatch: () -> Void
    }
    private var outputMatchers: [UUID: OutputMatcher] = [:]

    /// Registers `needle` to fire `onMatch` once it appears in the output
    /// stream. Returns nil (and does not register) when the needle is already
    /// present in the current buffer, so the caller can resolve immediately.
    func registerOutputMatcher(_ needle: String, onMatch: @escaping () -> Void) -> UUID? {
        if recentOutputText().contains(needle) || visibleScreenText().contains(needle) {
            return nil
        }
        let id = UUID()
        let matcher = StreamingMatcher(needle: needle, seed: recentOutputText())
        outputMatchers[id] = OutputMatcher(matcher: matcher, onMatch: onMatch)
        return id
    }

    func cancelOutputMatcher(_ id: UUID) {
        outputMatchers[id] = nil
    }

    /// Feeds a freshly stripped output chunk to every pending matcher. Callbacks
    /// are collected and fired after the loop so an onMatch that cancels a
    /// matcher can't mutate `outputMatchers` mid-iteration.
    private func feedOutputMatchers(strippedChunk: String) {
        guard !outputMatchers.isEmpty else { return }
        var fired: [() -> Void] = []
        for id in Array(outputMatchers.keys) {
            guard var entry = outputMatchers[id] else { continue }
            if entry.matcher.feed(strippedChunk) {
                outputMatchers.removeValue(forKey: id)
                fired.append(entry.onMatch)
            } else {
                outputMatchers[id] = entry
            }
        }
        for onMatch in fired { onMatch() }
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

    /// True when shell integration is active and a command (e.g. nvim) is
    /// running in the foreground — image paste should not fire in this state.
    var isCommandRunning: Bool {
        hasShellIntegration && commandStartDate != nil
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
        Log.debug("🔄 Applying config to terminal: font=\(newConfig.font.family) size=\(newConfig.font.size) blur=\(newConfig.window.enableBlur)", category: "terminal")
        self.config = newConfig

        // Update font (respecting the current app-wide zoom)
        terminalView.font = terminalFont(for: newConfig)

        applyThemeColors()
        applyTerminalAppearance(newConfig)

        // Force terminal to refresh
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    /// Install the active theme's ANSI palette, foreground and cursor colors.
    /// Called at setup and again whenever the theme changes.
    private func applyThemeColors() {
        terminalView.installColors(Theme.shared.ansiColors)
        terminalView.nativeForegroundColor = Theme.shared.palette.text
        terminalView.caretColor = Theme.shared.palette.rosewater
    }

    private func applyTerminalAppearance(_ config: Config) {
        let baseColor = Theme.shared.palette.base

        if config.window.enableBlur {
            let alpha = CGFloat(max(0.0, min(1.0, config.window.opacity)))
            Log.debug("🎨 Setting terminal background alpha to \(alpha)", category: "terminal")
            let backgroundColor = baseColor.withAlphaComponent(alpha)
            view.layer?.backgroundColor = backgroundColor.cgColor
            view.layer?.isOpaque = false
            // Clear native background so the translucent container layer (and
            // the window blur behind it) shows through. Do NOT set
            // terminal.backgroundColor to an opaque color here: it is kept in
            // sync with nativeBackgroundColor by SwiftTerm, so an opaque value
            // would repaint every default cell opaque and defeat the blur.
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
            blockedPollingTimer?.invalidate()
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
