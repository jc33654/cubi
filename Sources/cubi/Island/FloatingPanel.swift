import AppKit

/// The island's home when dragged out of the notch: can sit on any screen. Like `IslandPanel` the
/// window keeps one size; the island is drawn at its top centre and grows downwards.
final class FloatingPanel: OverlayPanel {
    static let size = CGSize(width: 1000, height: 700)

    init() {
        super.init(size: Self.size, level: .floating, stationary: false)
    }
}
