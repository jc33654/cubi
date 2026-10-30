import AppKit

/// A transparent, always-on-top, non-activating panel pinned to the top of the screen. The island
/// itself is drawn inside it with SwiftUI; the panel never changes size, only its content does.
final class IslandPanel: NSPanel {
    static let size = CGSize(width: 1000, height: 700)

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Above the menu bar so the island can overlap the notch.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// Shown on right-click anywhere on the island: the same menu as the menubar item, which the
    /// notch can push out of sight when the menubar is crowded.
    var contextMenu: NSMenu?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu, let view = contentView else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
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
