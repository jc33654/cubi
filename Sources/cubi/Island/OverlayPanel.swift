import AppKit

/// What the notch panel and the floating panel share: transparent, borderless, never activating,
/// a right-click menu, and a fixed size the island is drawn inside of.
class OverlayPanel: NSPanel {
    init(size: CGSize, level: NSWindow.Level, stationary: Bool) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        self.level = level
        collectionBehavior = stationary
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
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
}
