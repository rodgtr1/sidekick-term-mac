import Foundation

/// Watches ~/.config/sidekick/config.toml and fires `onChange` (on the main
/// queue) when its contents change. The parent directory is watched, not the
/// file itself, so atomic saves (write-temp-then-rename, used by most
/// editors) are detected too.
// `nonisolated` + `@unchecked Sendable`: the watcher lives on its own
// DispatchSource / debounce queues (utility), never the main actor. Its mutable
// state is touched only from those serialized contexts plus start()/stop() at
// setup/teardown — the same hand-audited concurrency contract the IPC layer
// uses. The only hop back to the UI is `onChange`, a main-actor callback.
nonisolated final class ConfigWatcher: @unchecked Sendable {
    var onChange: (@MainActor () -> Void)?

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
        // Use the pointer-returning result of realpath so we hit String's
        // (non-deprecated) UnsafePointer<CChar> overload rather than the
        // deprecated [CChar] array initializer.
        if let resolvedPtr = realpath(path, &buffer) {
            return String(cString: resolvedPtr)
        }
        return path
    }

    func start() {
        stop()

        watchedPath = resolved(configPath)
        let directory = (watchedPath as NSString).deletingLastPathComponent
        directoryFD = open(directory, O_EVTONLY)
        guard directoryFD >= 0 else {
            Log.error("ConfigWatcher: cannot open \(directory)", category: "config")
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
                MainActor.assumeIsolated {
                    self.onChange?()
                }
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
