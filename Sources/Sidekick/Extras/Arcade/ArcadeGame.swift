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

    /// Restores from a previously encoded blob; a nil or undecodable blob
    /// means "start fresh".
    init(savedState: Data?)

    /// The playfield. The panel makes it first responder while visible.
    var view: NSView { get }

    /// Asks the panel to hide (Esc / the toggle chord pressed inside the game).
    var onCloseRequested: (() -> Void)? { get set }

    func pause()
    func resume()

    /// Snapshot for arcade.json. nil when there is nothing worth keeping.
    func encodeState() -> Data?
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
        let make: (Data?) -> any ArcadeGame
    }

    static let games: [Entry] = [
        Entry(id: BlocksGameView.gameID, title: BlocksGameView.title) { BlocksGameView(savedState: $0) },
        Entry(id: DepthLadderView.gameID, title: DepthLadderView.title) { DepthLadderView(savedState: $0) },
        Entry(id: TwoLinesView.gameID, title: TwoLinesView.title) { TwoLinesView(savedState: $0) },
        Entry(id: KeysmithView.gameID, title: KeysmithView.title) { KeysmithView(savedState: $0) },
        Entry(id: GroveView.gameID, title: GroveView.title) { GroveView(savedState: $0) },
        Entry(id: WalkView.gameID, title: WalkView.title) { WalkView(savedState: $0) },
        Entry(id: CartographyView.gameID, title: CartographyView.title) { CartographyView(savedState: $0) }
    ]
}
