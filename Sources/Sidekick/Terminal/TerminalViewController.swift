import Cocoa
import SwiftTerm

protocol TerminalViewControllerDelegate: AnyObject {
    func terminalDidUpdateTitle(_ terminal: TerminalViewController, directory: String, branch: String?)
    func terminalDidDetectAgentState(_ terminal: TerminalViewController, state: AgentState)
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
    weak var delegate: TerminalViewControllerDelegate?
    private var terminalView: LocalProcessTerminalView!
    private var config: Config
    private var cwdTimer: Timer?
    private var currentCWD: String = "~"
    private var shellPID: pid_t = 0
    private var initialDirectory: String?
    private var recentOutput = ""
    private var lastDetectedAgentState: AgentState = .idle
    private var agentDoneTimer: Timer?

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Focus terminal after view appears
        focusTerminal()
    }

    private func setupTerminal() {
        let font = NSFont(name: config.font.family, size: CGFloat(config.font.size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(config.font.size), weight: .regular)

        print("🔤 Terminal font: \(font.fontName) size: \(font.pointSize)")

        let agentAwareTerminalView = AgentAwareTerminalView(frame: view.bounds)
        agentAwareTerminalView.onOutput = { [weak self] output in
            DispatchQueue.main.async {
                self?.detectAgentState(from: output)
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

        // Install Catppuccin Mocha color palette
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

        // Use initialDirectory if provided, otherwise use home directory
        let startDirectory = initialDirectory ?? homeDirectory

        // Change to the starting directory before starting shell
        // This sets the working directory for the child process
        FileManager.default.changeCurrentDirectoryPath(startDirectory)

        // Start the shell process - let SwiftTerm handle environment setup
        // SwiftTerm will automatically set TERM, HOME, PWD and other required variables
        terminalView.startProcess(executable: shell, execName: shellIdiom)

        // Find the shell PID after a brief delay to allow process to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.findShellPID()
            // Trigger initial CWD update
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

        if let cwd = CWDDetector.getCWD(for: shellPID) {
            currentCWD = cwd
            updateTitle()
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
        shellPID = 0
    }

    private func findShellPID() {
        // Find the child process of the terminal
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-x", "-o", "pid,ppid,comm"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.split(separator: "\n")
                let myPid = ProcessInfo.processInfo.processIdentifier

                for line in lines {
                    let components = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                    if components.count >= 3,
                       let pid = pid_t(components[0]),
                       let ppid = pid_t(components[1]),
                       ppid == myPid {
                        shellPID = pid
                        break
                    }
                }
            }
        } catch {}
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
        if let directory = directory {
            // Try to parse as URL and extract path
            if let url = URL(string: directory), url.scheme == "file" {
                currentCWD = url.path
            } else {
                // Fall back to using it as-is if not a URL
                currentCWD = directory
            }
            updateTitle()
        }
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

    private func detectAgentState(from output: String) {
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
        } else if containsAgentWorkingCue(normalizedCurrentOutput) {
            notifyDetectedAgentState(.working)
            scheduleDoneAfterQuietPeriod()
        } else if lastDetectedAgentState == .working {
            scheduleDoneAfterQuietPeriod()
        }
    }

    private func normalizeTerminalOutput(_ output: String) -> String {
        return output
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
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

    func applyConfig(_ newConfig: Config) {
        print("🔄 Applying config to terminal: font=\(newConfig.font.family) size=\(newConfig.font.size) blur=\(newConfig.window.enableBlur)")
        self.config = newConfig

        // Update font
        if let font = NSFont(name: newConfig.font.family, size: CGFloat(newConfig.font.size)) {
            print("🔤 Setting font: \(font.fontName) size: \(font.pointSize)")
            terminalView.font = font
        } else {
            let fallbackFont = NSFont.monospacedSystemFont(ofSize: CGFloat(newConfig.font.size), weight: .regular)
            print("🔤 Using fallback font: \(fallbackFont.fontName) size: \(fallbackFont.pointSize)")
            terminalView.font = fallbackFont
        }

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
        }
    }
}
