import AppKit
import SwiftUI

/// The floating window's lifecycle and dragging. `IslandController` owns one and forwards to it.
@MainActor
final class FloatingController {
    let state: IslandState
    private(set) var panel: FloatingPanel?
    /// Offset of the pointer from the panel's origin while a drag is in progress.
    private var grab: CGPoint?
    var contextMenu: NSMenu? { didSet { panel?.contextMenu = contextMenu } }
    private let onTap: () -> Void
    private let onDrag: (IslandDrag) -> Void

    init(state: IslandState, onTap: @escaping () -> Void, onDrag: @escaping (IslandDrag) -> Void) {
        self.state = state
        self.onTap = onTap
        self.onDrag = onDrag
    }

    var isDragging: Bool { grab != nil }

    /// Shows the panel with its island's top centre at `islandTop` (screen coordinates), else where
    /// it last was, else (first use from the menu) at the top of the screen the pointer is on.
    func show(islandTopAt islandTop: CGPoint? = nil) {
        let p = panel ?? makePanel()
        let anchor = islandTop ?? state.floatingAnchor ?? {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let f = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            return CGPoint(x: f.midX, y: f.maxY - 8)
        }()
        p.setFrameOrigin(clamped(Self.origin(forAnchor: anchor)))
        remember(p)
        p.orderFrontRegardless()
    }

    private static func origin(forAnchor a: CGPoint) -> CGPoint {
        CGPoint(x: a.x - FloatingPanel.size.width / 2, y: a.y - FloatingPanel.size.height)
    }

    private static func anchor(of p: NSPanel) -> CGPoint {
        CGPoint(x: p.frame.midX, y: p.frame.maxY)
    }

    /// Saves where the island is and which screen it is on.
    private func remember(_ p: NSPanel) {
        let a = Self.anchor(of: p)
        state.floatingAnchor = a
        state.floatingScreenFrame = NSScreen.screens.first { $0.frame.contains(a) }?.visibleFrame
    }

    func hide() {
        panel?.orderOut(nil)
        grab = nil
    }

    /// The island's rectangle in screen coordinates for the current mode (nil when not shown).
    func islandRect() -> CGRect? {
        guard let p = panel, p.isVisible else { return nil }
        let size = state.floatingSize(for: state.mode)
        return CGRect(x: p.frame.midX - size.width / 2, y: p.frame.maxY - size.height, width: size.width, height: size.height)
    }

    var ignoresMouseEvents: Bool {
        get { panel?.ignoresMouseEvents ?? true }
        set { panel?.ignoresMouseEvents = newValue }
    }

    // MARK: - Dragging (screen coordinates from NSEvent, so the window following the pointer
    // does not feed back into the gesture's translation)

    func dragMoved(mouse: CGPoint) {
        guard let p = panel else { return }
        if grab == nil {
            // For the drag the window shrinks to the island. With separate Spaces per display a
            // window is shown on the display most of its frame is on, so the 1000 pt transparent
            // frame kept the island stuck at the edge while the pointer was already next door.
            let anchor = Self.anchor(of: p)
            let island = state.floatingSize(for: state.mode)
            let size = CGSize(width: island.width + 40, height: island.height + 40)
            p.setFrame(CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
            grab = CGPoint(x: mouse.x - p.frame.origin.x, y: mouse.y - p.frame.origin.y)
            p.ignoresMouseEvents = false
        }
        let g = grab!
        p.setFrameOrigin(CGPoint(x: mouse.x - g.x, y: mouse.y - g.y))
    }

    /// Ends the drag; true when the island was dropped onto the island's home spot at the top of
    /// the main screen (the notch, or the bar on a Mac without one) and should dock again.
    func dragEnded(notch: NotchGeometry) -> Bool {
        grab = nil
        guard let p = panel else { return false }
        // Back to the full frame, the island staying where it was dropped.
        p.setFrame(CGRect(origin: Self.origin(forAnchor: Self.anchor(of: p)), size: FloatingPanel.size), display: true)
        guard let rect = islandRect() else { return false }
        let f = notch.screenFrame
        if rect.maxY >= f.maxY - 60, abs(rect.midX - f.midX) <= 200 { return true }
        p.setFrameOrigin(clamped(p.frame.origin))
        remember(p)
        return false
    }

    /// Keeps the island's top strip on some screen after displays change (not mid-drag: the
    /// window is island-sized then and `clamped` assumes the full frame).
    func clampToScreens() {
        guard let p = panel, p.isVisible, !isDragging else { return }
        let o = clamped(p.frame.origin)
        if o != p.frame.origin { p.setFrameOrigin(o) }
        remember(p)
    }

    private func clamped(_ origin: CGPoint) -> CGPoint {
        let size = FloatingPanel.size
        let islandW = state.floatingSize(for: .compact).width
        // The visible island is the top ~40 pt of the panel, centred.
        let island = CGRect(x: origin.x + (size.width - islandW) / 2, y: origin.y + size.height - 40, width: islandW, height: 40)
        let screens = NSScreen.screens.map(\.visibleFrame)
        if screens.contains(where: { $0.intersects(island) }) { return origin }
        guard let nearest = screens.min(by: { distance($0, island) < distance($1, island) }) else { return origin }
        var x = origin.x, y = origin.y
        x = min(max(x, nearest.minX - (size.width - islandW) / 2), nearest.maxX - (size.width + islandW) / 2)
        y = min(max(y, nearest.minY - size.height + 40), nearest.maxY - size.height)
        return CGPoint(x: x, y: y)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return dx * dx + dy * dy
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel()
        let root = FloatingRootView(state: state, onTap: onTap, onDrag: onDrag)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: FloatingPanel.size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        p.contextMenu = contextMenu
        panel = p
        return p
    }
}
