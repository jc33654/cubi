import Foundation

/// The island's sizes for each mode, derived from the notch, the robots and what is shown.
/// Pure geometry: nothing here is stored.
extension IslandState {
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
    /// The robot row with the notch gap (or the floating gap) and the usage wing: the expanded
    /// island is never narrower than this, or robots would hang out of its left edge.
    var wingRowWidth: CGFloat {
        leftWingWidth + (placement == .notch ? geometry.notchWidth : Self.floatingGap) + Self.rightWingWidth
    }
    /// Wider with the info panel open; the height follows whatever is shown (cards, diff, list).
    var expandedWidth: CGFloat {
        let base = pendingCards.isEmpty && showingDiffFor == nil && selectedSession != nil ? Self.detailWidth : Self.expandedBaseWidth
        return max(base, wingRowWidth + 16)
    }
    /// Never wider than its screen, taller than most of it, or bigger than the panel it is drawn in.
    var maxExpandedSize: CGSize {
        let screen = placement == .floating ? (floatingScreenFrame ?? geometry.screenFrame) : geometry.screenFrame
        let panel = placement == .floating ? FloatingPanel.size : IslandPanel.size
        return CGSize(width: min(screen.width - 80, panel.width - 20),
                      height: min((screen.height * 0.7).rounded(), panel.height - 20))
    }
    var expandedSize: CGSize {
        CGSize(width: min(expandedWidth, maxExpandedSize.width), height: min(expandedHeight, maxExpandedSize.height))
    }
    /// Right wing: the usage readout. Left wing: the robots, growing with their number.
    /// Usage readout plus the ＋ button.
    static let rightWingWidth: CGFloat = 118
    static let minLeftWingWidth: CGFloat = 90
    /// Robot size on the wings: 36 pt on a 32 pt notch at the regular setting.
    var botSize: CGFloat { max(16, ((geometry.notchHeight + 4) * botSizeChoice.factor).rounded()) }
    /// The compact island hangs below the notch so the robots can be larger than it.
    var compactHeight: CGFloat { botSize + 10 }
    static let restingPillWidth: CGFloat = 34
    var leftWingWidth: CGFloat {
        let pill = restingBots.isEmpty ? 0 : Self.restingPillWidth + 6
        return max(Self.minLeftWingWidth, 16 + CGFloat(activeBots.count) * wingSlot + pill)
    }
    /// The wings differ in width but the notch must stay in the middle: shift the whole island by
    /// half the difference (compact and expanded alike), otherwise the robots end up under the
    /// notch, or, with many of them, outside the island's left edge.
    var wingOffset: CGFloat { (Self.rightWingWidth - leftWingWidth) / 2 }
    func xOffset(for mode: IslandMode) -> CGFloat { mode == .hidden ? 0 : wingOffset }

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
