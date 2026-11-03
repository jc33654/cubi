import AppKit

/// The notch panel, pinned to the top of the screen; the island grows inside it, the window never moves.
/// Wide, because the island shifts sideways as robots arrive (`IslandState.wingOffset`): the
/// 860 pt info panel still fits with a dozen robots on the wing. Transparent, so hanging past
/// the edge of a narrower screen does no harm.
final class IslandPanel: OverlayPanel {
    static let size = CGSize(width: 1400, height: 700)

    init() {
        // Above the menu bar so the island can overlap the notch.
        super.init(size: Self.size, level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3), stationary: true)
    }

    /// macOS would otherwise push a window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Top centre of the given screen.
    func pin(to geometry: NotchGeometry) {
        let f = geometry.screenFrame
        let origin = CGPoint(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height)
        setFrame(CGRect(origin: origin, size: Self.size), display: true)
    }
}
