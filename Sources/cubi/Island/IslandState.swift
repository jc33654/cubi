import Foundation
import Observation
import CubiKit

enum IslandMode: Equatable {
    case hidden, compact, expanded
}

/// One robot on the island. `model` is advanced inside the Canvas draw closure every frame, so it
/// is kept out of observation on purpose: observing it would re-render the whole island per frame.
@MainActor
@Observable
final class BotRuntime: Identifiable {
    let id: String
    var name: String
    /// The colour the palette assigned; `color` is this unless the user picked one.
    var autoColor: RGB
    var color: RGB
    var shape: BotShape = .square
    /// One line of what the session is doing right now.
    var ticker = ""
    var stateLabel = "idle"
    var contextPercent: Double = 0
    var modelName: String?
    var lastEdit: EditSummary?
    var agent = "claude-code"
    /// In the 晚安 zone: off the wing, listed under its own heading.
    var resting = false
    var cwd: String?
    var client = HookClient()
    var startedAt: Double = 0
    var prompts = 0
    var toolCalls = 0
    var stats = SessionStats()
    /// When `stats` last changed, so the elapsed time keeps moving between status lines.
    var statsAt: Date?
    var costUSD: Double?
    var transcriptPath: String?
    /// Birth time of the transcript file, looked up once per path by the coordinator.
    var transcriptCreatedAt: Date?
    @ObservationIgnored var model = BotModel()
    /// Timestamp of the last drawn frame, for a real-time step (0 = not yet drawn).
    @ObservationIgnored var lastFrame: TimeInterval = 0

    init(id: String, name: String, color: RGB) {
        self.id = id
        self.name = name
        self.autoColor = color
        self.color = color
    }

    func apply(_ look: BotLook) {
        let shape = look.shape ?? .square
        if self.shape != shape { self.shape = shape }
        let color = look.colorIndex.map { SessionPalette.colors[max(0, min(SessionPalette.colors.count - 1, $0))] } ?? autoColor
        if self.color != color { self.color = color }
    }
}

@MainActor
@Observable
final class IslandState {
    var mode: IslandMode = .hidden {
        didSet { if mode == .hidden { cancelDrag() } }
    }
    var geometry: NotchGeometry
    var bots: [BotRuntime] = []
    /// True while something waits for the user (an approval, a question): the island does not auto-close.
    var holdOpen = false
    /// Cards waiting for a decision, oldest first. Set by the coordinator.
    var pendingCards: [PendingCard] = []
    /// Where a card's buttons report to. Set by the coordinator.
    @ObservationIgnored var onDecision: (UUID, Decision) -> Void = { _, _ in }
    /// Tapping a robot or a list row: bring that session's terminal to the front.
    @ObservationIgnored var onFocus: (String) -> Void = { _ in }
    /// 去睡覺 / 起床上班 / 放生, implemented by the coordinator.
    enum SessionAction { case rest, wake, dismiss }
    @ObservationIgnored var onSessionAction: (SessionAction, String) -> Void = { _, _ in }
    /// Something inside the island (the 💤 pill) asks to open the full view; the controller owns mode changes.
    @ObservationIgnored var onExpand: () -> Void = {}
    /// Start a Claude Code session: open the dialog (prefilled from a session when given), or
    /// reopen that very session (`claude --resume <id>`) in its project and terminal.
    enum NewSessionIntent { case dialog(fromSession: String?), resume(session: String) }
    @ObservationIgnored var onNewSession: (NewSessionIntent) -> Void = { _ in }
    /// Tool plugins' sections of the detail card; nil when rendering offline (no plugins).
    @ObservationIgnored var widgets: SessionWidgetStore?
    /// "開面板" in a plugin's section: (tool id, session id).
    @ObservationIgnored var onOpenTool: (String, String) -> Void = { _, _ in }

    /// 工作中: on the wing. 晚安: only in the list, counted on the wing.
    var activeBots: [BotRuntime] { bots.filter { !$0.resting } }
    var restingBots: [BotRuntime] { bots.filter { $0.resting } }

    // MARK: - Dragging a robot along the wing to rearrange

    /// The robot being dragged, and where its centre is in the wing's coordinate space.
    var draggingBot: String?
    var dragCenterX: CGFloat = 0
    /// Where inside the robot it was grabbed, so it does not jump to the pointer.
    private var grabOffset: CGFloat = 0
    /// The user dropped a robot: the new order of every session (resting ones included, demo excluded).
    @ObservationIgnored var onReorder: ([String]) -> Void = { _ in }

    /// Gap between robots on the wing; the drop slot maths relies on the HStack using the same.
    static let botSpacing: CGFloat = 6
    /// One robot plus the gap after it.
    var wingSlot: CGFloat { botSize + Self.botSpacing }
    func slotCenter(_ index: Int) -> CGFloat { CGFloat(index) * wingSlot + botSize / 2 }

    /// Moves the dragged robot to the slot under its centre, live; resting robots keep their places.
    /// `start` is where the drag began, `x` where the pointer is now (both in the wing's space).
    func dragBot(_ id: String, from start: CGFloat, to x: CGFloat) {
        let active = activeBots
        guard let from = active.firstIndex(where: { $0.id == id }) else { return cancelDrag() }
        if draggingBot != id {
            draggingBot = id
            grabOffset = start - slotCenter(from)
        }
        dragCenterX = x - grabOffset
        let to = max(0, min(active.count - 1, Int(dragCenterX / wingSlot)))
        guard to != from else { return }
        var reordered = active
        reordered.insert(reordered.remove(at: from), at: to)
        var next = reordered.makeIterator()
        bots = bots.map { $0.resting ? $0 : next.next()! }
    }

    /// Dropped: the arrangement on the island becomes the store's.
    func endDrag() {
        guard draggingBot != nil else { return }
        draggingBot = nil
        onReorder(bots.map(\.id).filter { $0 != "demo" })
    }

    /// The island hid mid-drag: no drop is coming, keep what was arranged. (A robot vanishing
    /// mid-drag is handled by the coordinator's sync, which must not come back through onReorder.)
    func cancelDrag() { endDrag() }
    /// A look changed: the coordinator rebuilds anything that carries the colour (open cards).
    @ObservationIgnored var onLooksChanged: () -> Void = {}
    /// Session whose last diff is open in the expanded view.
    var showingDiffFor: String?
    /// Session whose info panel is open beside the list.
    var selectedSession: String?
    /// Expanded height follows the card being shown.
    var expandedHeight: CGFloat = 190
    /// Account-wide plan usage from the latest status line; nil until one arrives.
    var usage: StatuslineInfo?
    /// User setting: the island never hides; its resting mode is compact so every robot stays visible.
    var pinned: Bool {
        didSet { if persists { UserDefaults.standard.set(pinned, forKey: Self.pinnedKey) } }
    }
    /// User setting: with the island resting compact (pinned, or floating), hovering opens the full
    /// view. Off: hovering leaves it compact and a click opens it.
    var expandOnHover: Bool {
        didSet { if persists { UserDefaults.standard.set(expandOnHover, forKey: Self.expandOnHoverKey) } }
    }
    /// User setting: how big the robots are drawn; the compact island's height follows.
    var botSizeChoice: BotSizeChoice {
        didSet { if persists { UserDefaults.standard.set(botSizeChoice.rawValue, forKey: Self.botSizeKey) } }
    }
    /// Off for offline renders (`--render-island`), which must not leave settings behind.
    @ObservationIgnored var persists = true
    static let pinnedKey = "islandPinned"
    static let expandOnHoverKey = "islandExpandOnHover"
    static let botSizeKey = "botSize"

    enum BotSizeChoice: String, CaseIterable {
        case small, regular, large

        var displayName: String {
            switch self {
            case .small: return "小"
            case .regular: return "預設"
            case .large: return "大"
            }
        }
        /// Relative to the regular size (36 pt on a 32 pt notch): 28 / 36 / 44.
        var factor: CGFloat {
            switch self {
            case .small: return 0.78
            case .regular: return 1
            case .large: return 1.22
            }
        }
    }

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        let defaults = UserDefaults.standard
        self.pinned = defaults.bool(forKey: Self.pinnedKey)
        self.expandOnHover = defaults.object(forKey: Self.expandOnHoverKey) as? Bool ?? true
        self.botSizeChoice = BotSizeChoice(rawValue: defaults.string(forKey: Self.botSizeKey) ?? "") ?? .regular
    }

    // MARK: - Per-session looks (shape / colour the user picked). The coordinator persists them, so
    // a session keeps its look when it comes back and across launches.

    private(set) var looks = BotLooks()

    /// Looks saved by a previous run.
    func seedLooks(_ saved: BotLooks) {
        looks = saved
        for bot in bots { bot.apply(looks.look(for: bot.id)) }
    }

    func setShape(_ shape: BotShape?, for sessionID: String) {
        looks.setShape(shape, for: sessionID)
        looksChanged(sessionID)
    }

    func setColorIndex(_ index: Int?, for sessionID: String) {
        looks.setColorIndex(index, for: sessionID)
        looksChanged(sessionID)
    }

    /// Only over the cap: looks of sessions that are not live go, oldest choice first.
    func pruneLooks(keeping live: Set<String>) { looks.prune(keeping: live) }

    private func looksChanged(_ sessionID: String) {
        bots.first { $0.id == sessionID }?.apply(looks.look(for: sessionID))
        onLooksChanged()
        let l = looks.look(for: sessionID)
        CubiLog.write("look session=\(sessionID.prefix(8)) shape=\(l.shape?.rawValue ?? "-") color=\(l.colorIndex.map(String.init) ?? "auto")")
    }

    /// Where auto-close ends up. The floating window has nothing to hide behind: it rests compact.
    var restingMode: IslandMode { pinned || placement == .floating ? .compact : .hidden }

    // MARK: - Placement: in the notch, or a floating window the user dragged out

    enum Placement: String { case notch, floating }
    static let placementKey = "islandPlacement"
    static let floatingAnchorKey = "floatingAnchor"

    var placement: Placement = Placement(rawValue: UserDefaults.standard.string(forKey: IslandState.placementKey) ?? "") ?? .notch {
        didSet { if persists { UserDefaults.standard.set(placement.rawValue, forKey: Self.placementKey) } }
    }
    /// Top centre of the floating island in screen coordinates, remembered across launches
    /// (independent of the panel's size, which may change between builds).
    var floatingAnchor: CGPoint? = UserDefaults.standard.string(forKey: IslandState.floatingAnchorKey).map(NSPointFromString) {
        didSet { if persists { UserDefaults.standard.set(floatingAnchor.map(NSStringFromPoint), forKey: Self.floatingAnchorKey) } }
    }
    /// Visible frame of the screen the floating island sits on; sizes are clamped to it.
    var floatingScreenFrame: CGRect?

    /// What the notch panel draws: nothing while the island is floating.
    var notchMode: IslandMode { placement == .notch ? mode : .hidden }
}
