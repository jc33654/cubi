import AppKit

/// The island's home when dragged out of the notch: a transparent always-on-top panel that can sit
/// on any screen. Like `IslandPanel` the window keeps one size; the island is drawn at its top
/// centre and grows downwards.
final class FloatingPanel: NSPanel {
    static let size = CGSize(width: 640, height: 400)

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
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    var contextMenu: NSMenu?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu, let view = contentView else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
