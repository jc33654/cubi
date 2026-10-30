import SwiftUI
import CubiKit

/// The floating window's island: a fully rounded black card with a drag handle along its top edge.
struct FloatingRootView: View {
    @Bindable var state: IslandState
    var onTap: () -> Void
    var onDrag: (IslandDrag) -> Void

    @State private var width: CGFloat
    @State private var height: CGFloat

    init(state: IslandState, onTap: @escaping () -> Void, onDrag: @escaping (IslandDrag) -> Void) {
        self.state = state
        self.onTap = onTap
        self.onDrag = onDrag
        let size = state.floatingSize(for: state.mode)
        _width = State(initialValue: size.width)
        _height = State(initialValue: size.height)
    }

    var body: some View {
        let shell = RoundedRectangle(cornerRadius: IslandState.floatingRadius, style: .continuous)
        ZStack(alignment: .top) {
            shell.fill(.black)
            IslandContent(state: state, anchored: false)
                .frame(width: width, height: height, alignment: .top)
                .clipShape(shell)
            // Drag handle: a faint bar so the window reads as movable.
            Capsule().fill(.white.opacity(0.18)).frame(width: 36, height: 3).padding(.top, 3)
        }
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(shell)
        .onTapGesture { onTap() }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { _ in onDrag(.moved) }
            .onEnded { _ in onDrag(.ended) })
        .onChange(of: state.bots.count) { _, _ in apply(animated: true) }
        .onAppear { apply(animated: false) }
        .onChange(of: state.mode) { _, _ in apply(animated: true) }
        .onChange(of: state.expandedHeight) { _, _ in if state.mode == .expanded { apply(animated: true) } }
        .onChange(of: state.expandedWidth) { _, _ in if state.mode == .expanded { apply(animated: true) } }
    }

    private func apply(animated: Bool) {
        let size = state.floatingSize(for: state.mode)
        let shrinking = size.width < width
        let change = { width = size.width; height = size.height }
        if animated {
            withAnimation(shrinking ? IslandAnimation.closeEase : IslandAnimation.openSpring, change)
        } else {
            change()
        }
    }
}
