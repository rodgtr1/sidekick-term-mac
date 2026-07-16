import Cocoa

/// One game the arcade panel can host. Each game is a self-contained module:
/// it renders into `view`, owns its own input and timers, and round-trips its
/// entire state (including high scores) through an opaque Data blob so the
/// panel can persist every game uniformly without knowing any game's shape.
@MainActor
protocol ArcadeGame: AnyObject {
    /// Stable identifier used as the persistence key — never change it once
    /// shipped or saved games are orphaned.
    static var gameID: String { get }
    static var title: String { get }
    /// Short, complete directions shown by the arcade panel's How to Play
    /// button and ⌘? shortcut.
    static var howToPlay: String { get }

    /// Restores from a previously encoded blob; a nil or undecodable blob
    /// means "start fresh".
    init(savedState: Data?)

    /// The playfield. The panel makes it first responder while visible.
    var view: NSView { get }

    /// Asks the panel to hide (Esc / the toggle chord pressed inside the game).
    var onCloseRequested: (() -> Void)? { get set }

    func pause()
    func resume()

    /// Optional lifecycle hooks for games with live timers. The panel invokes
    /// these around the How to Play sheet; untimed games need no special work.
    func willShowHelp()
    func didDismissHelp()

    /// Snapshot for arcade.json. nil when there is nothing worth keeping.
    func encodeState() -> Data?
}

extension ArcadeGame {
    func willShowHelp() {}
    func didDismissHelp() {}
}

/// The games the panel can host, in display order. Adding a game to the
/// arcade means conforming to `ArcadeGame` and appending an entry here —
/// the panel, persistence, and (once there are several) the game switcher
/// all pick it up from this table.
@MainActor
enum ArcadeGameCatalog {
    struct Entry {
        let id: String
        let title: String
        let howToPlay: String
        let make: (Data?) -> any ArcadeGame
    }

    static let games: [Entry] = [
        entry(for: BlocksGameView.self),
        entry(for: DepthLadderView.self),
        entry(for: TwoLinesView.self),
        entry(for: KeysmithView.self),
        entry(for: GroveView.self),
        entry(for: WalkView.self),
        entry(for: CartographyView.self),
        entry(for: PondView.self)
    ]

    private static func entry<Game: ArcadeGame>(for type: Game.Type) -> Entry {
        Entry(id: type.gameID, title: type.title, howToPlay: type.howToPlay) {
            Game(savedState: $0)
        }
    }
}
