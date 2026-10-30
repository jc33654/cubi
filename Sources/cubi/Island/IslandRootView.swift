import SwiftUI
import CubiKit

/// Everything inside the notch panel. The island grows and shrinks here; the window never moves.
/// While the island lives in the floating window this draws nothing.
struct IslandRootView: View {
    @Bindable var state: IslandState
    var onTap: () -> Void
    /// Pointer dragged far enough on the island: the controller turns it into the floating window.
    var onDrag: (IslandDrag) -> Void

    @State private var width: CGFloat
    @State private var height: CGFloat
    @State private var radius: CGFloat
    @State private var xOffset: CGFloat

    init(state: IslandState, onTap: @escaping () -> Void, onDrag: @escaping (IslandDrag) -> Void = { _ in }) {
        self.state = state
        self.onTap = onTap
        self.onDrag = onDrag
        let mode = state.notchMode
        let size = state.size(for: mode)
        _width = State(initialValue: size.width)
        _height = State(initialValue: size.height)
        _radius = State(initialValue: state.cornerRadius(for: mode))
        _xOffset = State(initialValue: state.xOffset(for: mode))
    }

    var body: some View {
        ZStack(alignment: .top) {
            IslandShape(width: width, height: height, radius: radius)
                .fill(.black)
            IslandContent(state: state, anchored: true)
                .frame(width: width, height: height, alignment: .top)
                .clipShape(IslandShape(width: width, height: height, radius: radius))
                .opacity(state.placement == .notch ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(IslandShape(width: width, height: height, radius: radius))
        .onTapGesture { onTap() }
        .gesture(DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .onChanged { _ in onDrag(.moved) }
            .onEnded { _ in onDrag(.ended) })
        .offset(x: xOffset)
        .onChange(of: state.bots.count) { _, _ in apply(animated: true) }
        .onAppear { apply(animated: false) }
        .onChange(of: state.mode) { _, _ in apply(animated: true) }
        .onChange(of: state.placement) { _, _ in apply(animated: true) }
        .onChange(of: state.geometry) { _, _ in apply(animated: false) }
        .onChange(of: state.expandedHeight) { _, _ in if state.mode == .expanded { apply(animated: true) } }
        .onChange(of: state.expandedWidth) { _, _ in if state.mode == .expanded { apply(animated: true) } }
    }

    private func apply(animated: Bool) {
        let mode = state.notchMode
        let size = state.size(for: mode)
        let r = state.cornerRadius(for: mode)
        let shrinking = size.width < width
        let change = {
            width = size.width
            height = size.height
            radius = r
            xOffset = state.xOffset(for: mode)
        }
        if animated {
            withAnimation(shrinking ? IslandAnimation.closeEase : IslandAnimation.openSpring, change)
        } else {
            change()
        }
    }
}

enum IslandDrag { case moved, ended }

enum IslandAnimation {
    static let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    static let closeEase = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
}
