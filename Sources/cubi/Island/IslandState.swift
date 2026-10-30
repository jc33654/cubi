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
    var cwd: String?
    var client = HookClient()
    var startedAt: Double = 0
    var prompts = 0
    var toolCalls = 0
    var stats = SessionStats()
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
        let color = look.colorIndex.map { SessionPalette.colors[$0] } ?? autoColor
        if self.color != color { self.color = color }
    }
}

@MainActor
@Observable
final class IslandState {
    var mode: IslandMode = .hidden
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
    /// Off for offline renders (`--render-island`), which must not leave settings behind.
    @ObservationIgnored var persists = true
    static let pinnedKey = "islandPinned"

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        self.pinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)
        if let data = UserDefaults.standard.data(forKey: Self.looksKey), let saved = try? JSONDecoder().decode(BotLooks.self, from: data) {
            looks = saved
        }
    }

    // MARK: - Per-session looks (shape / colour the user picked)

    static let looksKey = "botLooks"
    private(set) var looks = BotLooks()

    func setShape(_ shape: BotShape?, for sessionID: String) {
        looks.setShape(shape, for: sessionID)
        looksChanged(sessionID)
    }

    func setColorIndex(_ index: Int?, for sessionID: String) {
        looks.setColorIndex(index, for: sessionID)
        looksChanged(sessionID)
    }

    /// The session is gone: forget its look.
    func forgetLook(_ sessionID: String) {
        guard looks.bySession[sessionID] != nil else { return }
        looks.remove(sessionID)
        saveLooks()
    }

    private func looksChanged(_ sessionID: String) {
        bots.first { $0.id == sessionID }?.apply(looks.look(for: sessionID))
        saveLooks()
        let l = looks.look(for: sessionID)
        CubiLog.write("look session=\(sessionID.prefix(8)) shape=\(l.shape?.rawValue ?? "-") color=\(l.colorIndex.map(String.init) ?? "auto")")
    }

    private func saveLooks() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(looks) { UserDefaults.standard.set(data, forKey: Self.looksKey) }
    }

    /// Where auto-close ends up. The floating window has nothing to hide behind: it rests compact.
    var restingMode: IslandMode { pinned || placement == .floating ? .compact : .hidden }

    // MARK: - Placement: in the notch, or a floating window the user dragged out

    enum Placement: String { case notch, floating }
    static let placementKey = "islandPlacement"
    static let floatingOriginKey = "floatingOrigin"

    var placement: Placement = Placement(rawValue: UserDefaults.standard.string(forKey: IslandState.placementKey) ?? "") ?? .notch {
        didSet { if persists { UserDefaults.standard.set(placement.rawValue, forKey: Self.placementKey) } }
    }
    /// Bottom-left of the floating panel in screen coordinates, remembered across launches.
    var floatingOrigin: CGPoint? = {
        guard let a = UserDefaults.standard.array(forKey: IslandState.floatingOriginKey) as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }() {
        didSet { if persists { UserDefaults.standard.set(floatingOrigin.map { [$0.x, $0.y] }, forKey: Self.floatingOriginKey) } }
    }

    /// What the notch panel draws: nothing while the island is floating.
    var notchMode: IslandMode { placement == .notch ? mode : .hidden }

    /// Gap between the robot row and the usage readout in the floating window (no notch to skip).
    static let floatingGap: CGFloat = 14
    static let floatingRadius: CGFloat = 18

    func floatingSize(for mode: IslandMode) -> CGSize {
        switch mode {
        case .hidden, .compact: return CGSize(width: leftWingWidth + Self.floatingGap + Self.rightWingWidth, height: compactHeight)
        case .expanded: return expandedSize
        }
    }

    static let expandedBaseWidth: CGFloat = 640
    static let detailWidth: CGFloat = 860
    /// Wider with the info panel open; the height follows whatever is shown (cards, diff, list).
    var expandedWidth: CGFloat {
        pendingCards.isEmpty && showingDiffFor == nil && selectedSession != nil ? Self.detailWidth : Self.expandedBaseWidth
    }
    /// Never wider than the screen or taller than most of it.
    var maxExpandedSize: CGSize { CGSize(width: geometry.screenFrame.width - 80, height: (geometry.screenFrame.height * 0.7).rounded()) }
    var expandedSize: CGSize {
        CGSize(width: min(expandedWidth, maxExpandedSize.width), height: min(expandedHeight, maxExpandedSize.height))
    }
    /// Right wing: the usage readout. Left wing: the robots, growing with their number.
    static let rightWingWidth: CGFloat = 90
    static let minLeftWingWidth: CGFloat = 90
    /// The compact island hangs a little below the notch so the robots can be larger than it.
    static let compactExtraHeight: CGFloat = 14

    var compactHeight: CGFloat { geometry.notchHeight + Self.compactExtraHeight }
    /// Robot size on the wings: 36 pt on a 32 pt notch.
    var botSize: CGFloat { max(16, compactHeight - 10) }
    var leftWingWidth: CGFloat { max(Self.minLeftWingWidth, 16 + CGFloat(bots.count) * (botSize + 6)) }
    /// The wings differ in width but the notch must stay in the middle: shift the island (compact)
    /// or the wing row (expanded) by half the difference, otherwise the robots end up under the notch.
    var wingOffset: CGFloat { (Self.rightWingWidth - leftWingWidth) / 2 }
    func xOffset(for mode: IslandMode) -> CGFloat { mode == .compact ? wingOffset : 0 }

    func size(for mode: IslandMode) -> CGSize {
        switch mode {
        case .hidden:   return CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        case .compact:  return CGSize(width: geometry.notchWidth + leftWingWidth + Self.rightWingWidth, height: compactHeight)
        case .expanded: return expandedSize
        }
    }

    func cornerRadius(for mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden:   return geometry.hasNotch ? 10 : 8
        case .compact:  return 14
        case .expanded: return 22
        }
    }
}
