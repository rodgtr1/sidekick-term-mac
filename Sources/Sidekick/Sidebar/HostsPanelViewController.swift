import Cocoa

protocol HostsPanelDelegate: AnyObject {
    func hostsPanel(_ panel: HostsPanelViewController, didRequestConnectCommand command: String)
}

/// Sidebar panel listing connectable hosts: ~/.ssh/config entries and
/// Teleport nodes from `tsh ls`. Clicking a host opens a new tab running
/// the matching ssh / tsh ssh command.
final class HostsPanelViewController: NSViewController {
    weak var delegate: HostsPanelDelegate?

    private enum Item {
        case header(String)
        case host(name: String, detail: String?, command: String)
        case message(String)
    }

    private var items: [Item] = []
    private var sshHosts: [String] = []
    private var teleportNodes: [(name: String, detail: String?, command: String)] = []
    private var teleportMessage: String?
    private var showTeleport = false

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var refreshButton: NSButton!

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    private var themeObserver: ThemeObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        refresh()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        refreshButton?.contentTintColor = AppTheme.primaryText
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.reloadData()
    }

    private func setupViews() {
        refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") ?? NSImage(),
            target: self,
            action: #selector(refreshClicked)
        )
        refreshButton.isBordered = false
        refreshButton.contentTintColor = AppTheme.primaryText
        refreshButton.toolTip = "Refresh hosts"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = AppTheme.sidebarBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) {
            tableView.style = .plain
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HostColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        view.addSubview(refreshButton)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func refreshClicked() {
        refresh()
    }

    /// Enables or disables the Teleport section. When disabled, tsh is never
    /// invoked at all.
    func setShowTeleport(_ show: Bool) {
        guard show != showTeleport else { return }
        showTeleport = show
        if !show {
            teleportNodes = []
            teleportMessage = nil
        }
        if isViewLoaded {
            refresh()
        }
    }

    func refresh() {
        sshHosts = Self.parseSSHConfigHosts()
        rebuildItems()

        if showTeleport {
            loadTeleportNodes()
        }
    }

    private func rebuildItems() {
        var newItems: [Item] = []

        newItems.append(.header("SSH CONFIG"))
        if sshHosts.isEmpty {
            newItems.append(.message("No hosts in ~/.ssh/config"))
        } else {
            for host in sshHosts {
                newItems.append(.host(name: host, detail: nil, command: "ssh \(host)"))
            }
        }

        if showTeleport {
            newItems.append(.header("TELEPORT"))
            if let message = teleportMessage {
                newItems.append(.message(message))
            } else {
                for node in teleportNodes {
                    newItems.append(.host(name: node.name, detail: node.detail, command: node.command))
                }
            }
        }

        items = newItems
        tableView.reloadData()
    }

    // MARK: - SSH config parsing

    static func parseSSHConfigHosts() -> [String] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return parseSSHConfigHosts(from: contents)
    }

    static func parseSSHConfigHosts(from contents: String) -> [String] {
        var hosts: [String] = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("host "), !trimmed.hasPrefix("#") else { continue }

            let patterns = trimmed.dropFirst("host ".count)
                .split(separator: " ")
                .map(String.init)
            for pattern in patterns where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                hosts.append(pattern)
            }
        }
        return hosts
    }

    // MARK: - Teleport

    private func loadTeleportNodes() {
        guard let tshURL = ProcessRunner.executableURL(named: "tsh", commonPaths: [
            "/opt/homebrew/bin/tsh",
            "/usr/local/bin/tsh",
            "/usr/bin/tsh"
        ]) else {
            teleportMessage = "tsh not found"
            rebuildItems()
            return
        }

        teleportMessage = "Loading…"
        rebuildItems()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var nodes: [(String, String?, String)] = []
            var message: String?

            // `tsh ls` with an expired profile tries to reauthenticate
            // interactively and hangs without a TTY — so check the local
            // session state first, and put hard timeouts on both calls.
            let status = Self.runTsh(tshURL, arguments: ["status"], timeout: 5)
            if status.timedOut || status.exitCode != 0 {
                message = status.timedOut
                    ? "tsh not responding"
                    : "Session expired — run `tsh login`"
            } else {
                let list = Self.runTsh(tshURL, arguments: ["ls", "--format=json"], timeout: 15)
                if !list.timedOut, list.exitCode == 0,
                   let parsed = try? JSONSerialization.jsonObject(with: list.stdout) as? [[String: Any]] {
                    for entry in parsed {
                        let spec = entry["spec"] as? [String: Any]
                        let metadata = entry["metadata"] as? [String: Any]
                        guard let hostname = spec?["hostname"] as? String
                                ?? metadata?["name"] as? String else { continue }
                        let labels = metadata?["labels"] as? [String: Any]

                        // Beam instances list as nodes with a beam-<uuid>
                        // hostname, but tsh ssh can't dial that — they connect
                        // via `tsh beams ssh <alias>` using the friendly alias
                        // from their labels.
                        if let alias = labels?["teleport.internal/beams/alias"] as? String {
                            nodes.append((alias, "Teleport Beam", "tsh beams ssh \(alias)"))
                            continue
                        }

                        let labelText = labels?
                            .map { "\($0.key)=\($0.value)" }
                            .sorted()
                            .joined(separator: " ")
                        nodes.append((
                            hostname,
                            labelText?.isEmpty == false ? labelText : nil,
                            "tsh ssh \(hostname)"
                        ))
                    }
                    nodes.sort { $0.0 < $1.0 }
                } else {
                    message = list.timedOut ? "tsh ls timed out" : "Failed to list nodes"
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.showTeleport else { return }
                self.teleportNodes = nodes
                self.teleportMessage = nodes.isEmpty ? (message ?? "No nodes") : nil
                self.rebuildItems()
            }
        }
    }

    private struct TshResult {
        let exitCode: Int32
        let stdout: Data
        let timedOut: Bool
    }

    /// Runs tsh with a hard timeout, killing the process if it hangs
    /// (e.g. waiting for interactive reauthentication).
    private static func runTsh(_ url: URL, arguments: [String], timeout: TimeInterval) -> TshResult {
        let task = Process()
        task.executableURL = url
        task.arguments = arguments
        // Belt and suspenders: detach from any TTY-based prompting.
        var environment = ProcessInfo.processInfo.environment
        environment["TELEPORT_INTERACTIVE"] = "false"
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.standardInput = FileHandle.nullDevice

        // Collect output with a readability handler instead of a blocking
        // read-to-EOF: pipe FDs are inherited by any child process the app
        // spawns while tsh runs (shells, git), and a long-lived child holding
        // the write end means EOF never arrives even after tsh exits.
        let bufferLock = NSLock()
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                bufferLock.lock()
                buffer.append(chunk)
                bufferLock.unlock()
            }
        }

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }

        do {
            try task.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return TshResult(exitCode: -1, stdout: Data(), timedOut: false)
        }

        // Wait on process exit, not pipe EOF, so the timeout always holds.
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }

        // Brief grace period so the handler drains any final output.
        usleep(100_000)
        pipe.fileHandleForReading.readabilityHandler = nil
        bufferLock.lock()
        let data = buffer
        bufferLock.unlock()

        let exitCode = task.isRunning ? -1 : task.terminationStatus
        return TshResult(exitCode: exitCode, stdout: data, timedOut: timedOut)
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < items.count,
              case .host(_, _, let command) = items[row] else { return }
        delegate?.hostsPanel(self, didRequestConnectCommand: command)
    }
}

extension HostsPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

extension HostsPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let cell = NSTableCellView()

        switch items[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = AppTheme.mutedText
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)
            ])
        case .message(let text):
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = AppTheme.mutedText
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        case .host(let name, let detail, _):
            let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = AppTheme.accent
            icon.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = NSFont.systemFont(ofSize: 13)
            nameLabel.textColor = AppTheme.primaryText
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.toolTip = detail.map { "\(name)\n\($0)" } ?? "Double-click to connect to \(name)"

            cell.addSubview(icon)
            cell.addSubview(nameLabel)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),

                nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 26 }
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .host = items[row] { return true }
        return false
    }
}
