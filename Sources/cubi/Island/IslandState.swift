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

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    static let expandedSize = CGSize(width: 640, height: 190)
    static let compactExtraWidth: CGFloat = 180
    /// The compact island hangs a little below the notch so the robots can be larger than it.
    static let compactExtraHeight: CGFloat = 14

    var compactHeight: CGFloat { geometry.notchHeight + Self.compactExtraHeight }
    /// Robot size on the wings: 36 pt on a 32 pt notch.
    var botSize: CGFloat { max(16, compactHeight - 10) }

    func size(for mode: IslandMode) -> CGSize {
        switch mode {
        case .hidden:   return CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        case .compact:  return CGSize(width: geometry.notchWidth + Self.compactExtraWidth, height: compactHeight)
        case .expanded: return Self.expandedSize
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
