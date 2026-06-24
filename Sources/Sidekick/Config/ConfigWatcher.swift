import Foundation

/// Watches ~/.config/sidekick/config.toml and fires `onChange` (on the main
/// queue) when its contents change. The parent directory is watched, not the
/// file itself, so atomic saves (write-temp-then-rename, used by most
/// editors) are detected too.
final class ConfigWatcher {
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var debounceWork: DispatchWorkItem?
    private var lastModificationDate: Date?

    private let configPath = NSString(string: "~/.config/sidekick/config.toml").expandingTildeInPath
    // The path actually watched/stat'd. When config.toml is a symlink (e.g. a
    // stow/dotfiles link), this resolves to the real file so edits to the link
    // target are seen — otherwise we'd watch the wrong directory and read the
    // link's own (unchanging) modification date.
    private var watchedPath = ""

    /// Canonical path with symlinks and `..` resolved. Falls back to the input
    /// if the file does not exist yet.
    private func resolved(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(cString: buffer)
        }
        return path
    }

    func start() {
        stop()

        watchedPath = resolved(configPath)
        let directory = (watchedPath as NSString).deletingLastPathComponent
        directoryFD = open(directory, O_EVTONLY)
        guard directoryFD >= 0 else {
            print("ConfigWatcher: cannot open \(directory)")
            return
        }

        lastModificationDate = modificationDate()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReloadCheck()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.directoryFD, fd >= 0 {
                close(fd)
                self?.directoryFD = -1
            }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// The directory also holds the IPC socket and session file, so events
    /// fire for unrelated writes — only reload when config.toml itself changed.
    private func scheduleReloadCheck() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let current = self.modificationDate()
            guard current != self.lastModificationDate else { return }
            self.lastModificationDate = current
            DispatchQueue.main.async {
                self.onChange?()
            }
        }
        debounceWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: watchedPath))?[.modificationDate] as? Date
    }

    deinit {
        stop()
    }
}
