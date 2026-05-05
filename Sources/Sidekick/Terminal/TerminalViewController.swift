import Cocoa
import SwiftTerm

protocol TerminalViewControllerDelegate: AnyObject {
    func terminalDidUpdateTitle(_ terminal: TerminalViewController, directory: String, branch: String?)
}

class TerminalViewController: NSViewController, LocalProcessTerminalViewDelegate {
    weak var delegate: TerminalViewControllerDelegate?
    private var terminalView: LocalProcessTerminalView!
    private var config: Config
    private var cwdTimer: Timer?
    private var currentCWD: String = "~"
    private var shellPID: pid_t = 0

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTerminal()
        startShell()
        startCWDTracking()
    }

    private func setupTerminal() {
        let font = NSFont(name: config.font.family, size: CGFloat(config.font.size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(config.font.size), weight: .regular)

        terminalView = LocalProcessTerminalView(frame: view.bounds)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.font = font
        terminalView.installColors(ColorPalette.catppuccinMocha)

        // Make sure the view has a visible background
        terminalView.wantsLayer = true
        let backgroundColor = NSColor(hex: "#1e1e2e")!
        terminalView.layer?.backgroundColor = backgroundColor.cgColor
        terminalView.layer?.isOpaque = true

        terminalView.caretColor = NSColor(hex: "#f5e0dc")!

        // Set delegate to receive process events
        terminalView.processDelegate = self

        setupURLHandling()

        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func startShell() {
        let shell = getShell()
        let shellIdiom = "-" + NSString(string: shell).lastPathComponent

        // Change to home directory before starting shell
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.homeDirectoryForCurrentUser.path)

        // Start the shell process - don't pass empty environment, let SwiftTerm handle defaults
        terminalView.startProcess(executable: shell, execName: shellIdiom)
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
        // Update window title if needed
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.title = "\(title) - Sidekick"
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 command received - update current directory
        if let directory = directory {
            currentCWD = directory
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

    deinit {
        MainActor.assumeIsolated {
            cwdTimer?.invalidate()
        }
    }
}