import AppKit

/// Where the island lives on a given screen. On a notched display the resting island is exactly
/// the notch; elsewhere it is a small bar under the top edge.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static let fallbackNotchWidth: CGFloat = 184
    static let fallbackNotchHeight: CGFloat = 32
    static let barWidth: CGFloat = 80
    static let barHeight: CGFloat = 24

    static func measure(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0 {
            var width = fallbackNotchWidth
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                width = frame.width - left.width - right.width
            }
            return NotchGeometry(screenFrame: frame, hasNotch: true, notchWidth: width, notchHeight: top)
        }
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 0 ? min(barHeight, menuBar) : NSStatusBar.system.thickness
        return NotchGeometry(screenFrame: frame, hasNotch: false, notchWidth: barWidth, notchHeight: height)
    }

    /// The notched screen when there is one, otherwise the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}
