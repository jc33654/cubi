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
    var color: RGB
    /// One line of what the session is doing right now.
    var ticker = ""
    var stateLabel = "idle"
    var contextPercent: Double = 0
    var modelName: String?
    var lastEdit: EditSummary?
    var agent = "claude-code"
    @ObservationIgnored var model = BotModel()
    /// Timestamp of the last drawn frame, for a real-time step (0 = not yet drawn).
    @ObservationIgnored var lastFrame: TimeInterval = 0

    init(id: String, name: String, color: RGB) {
        self.id = id
        self.name = name
        self.color = color
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
    /// Expanded height follows the card being shown.
    var expandedHeight: CGFloat = 190
    /// Account-wide plan usage from the latest status line; nil until one arrives.
    var usage: StatuslineInfo?
    /// User setting: the island never hides; its resting mode is compact so every robot stays visible.
    var pinned: Bool {
        didSet { UserDefaults.standard.set(pinned, forKey: Self.pinnedKey) }
    }
    static let pinnedKey = "islandPinned"

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        self.pinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)
    }

    /// Where auto-close ends up.
    var restingMode: IslandMode { pinned ? .compact : .hidden }

    static let expandedSize = CGSize(width: 640, height: 190)
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
        case .expanded: return CGSize(width: Self.expandedSize.width, height: expandedHeight)
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
