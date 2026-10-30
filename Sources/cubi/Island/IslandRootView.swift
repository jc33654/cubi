import SwiftUI
import CubiKit

/// Everything inside the panel. The island grows and shrinks here; the window never moves.
struct IslandRootView: View {
    @Bindable var state: IslandState
    var onTap: () -> Void

    @State private var width: CGFloat
    @State private var height: CGFloat
    @State private var radius: CGFloat
    @State private var xOffset: CGFloat

    init(state: IslandState, onTap: @escaping () -> Void) {
        self.state = state
        self.onTap = onTap
        let size = state.size(for: state.mode)
        _width = State(initialValue: size.width)
        _height = State(initialValue: size.height)
        _radius = State(initialValue: state.cornerRadius(for: state.mode))
        _xOffset = State(initialValue: state.xOffset(for: state.mode))
    }

    private let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    private let closeEase = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)

    var body: some View {
        ZStack(alignment: .top) {
            IslandShape(width: width, height: height, radius: radius)
                .fill(.black)
            content
                .frame(width: width, height: height, alignment: .top)
                .clipShape(IslandShape(width: width, height: height, radius: radius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(IslandShape(width: width, height: height, radius: radius))
        .onTapGesture { onTap() }
        .offset(x: xOffset)
        .onChange(of: state.bots.count) { _, _ in apply(state.mode, animated: true) }
        .onAppear { apply(state.mode, animated: false) }
        .onChange(of: state.mode) { _, new in apply(new, animated: true) }
        .onChange(of: state.geometry) { _, _ in apply(state.mode, animated: false) }
        .onChange(of: state.expandedHeight) { _, _ in if state.mode == .expanded { apply(.expanded, animated: true) } }
    }

    private func apply(_ mode: IslandMode, animated: Bool) {
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
            withAnimation(shrinking ? closeEase : openSpring, change)
        } else {
            change()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .hidden:
            Color.clear
        case .compact:
            wings(height: state.compactHeight)
        case .expanded:
            VStack(spacing: 6) {
                wings(height: state.compactHeight)
                if let card = state.pendingCards.first {
                    cardView(card)
                } else if let id = state.showingDiffFor, let bot = state.bots.first(where: { $0.id == id }), let edit = bot.lastEdit {
                    DiffCardView(sessionName: bot.name, color: bot.color, summary: edit) { state.showingDiffFor = nil }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            let wanted = state.compactHeight + 6 + h
                            if abs(wanted - state.expandedHeight) > 1 { state.expandedHeight = wanted }
                        }
                } else {
                    UsageStripView(usage: state.usage)
                    SessionListView(state: state)
                        .padding(.bottom, 10)
                        .onAppear { if state.expandedHeight != 190 { state.expandedHeight = 190 } }
                }
            }
        }
    }

    /// The card takes its natural height and reports it, and the island grows to fit: no estimates.
    private func cardView(_ card: PendingCard) -> some View {
        Group {
            switch card.content {
            case .approval(let title, let detail, let canAlways):
                ApprovalCardView(card: card, title: title, detail: detail, canAlways: canAlways,
                                 waitingCount: state.pendingCards.count - 1) { d in state.onDecision(card.id, d) }
            case .question(let questions):
                QuestionCardView(card: card, questions: questions) { d in state.onDecision(card.id, d) }
            }
        }
        .id(card.id)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            let wanted = state.compactHeight + 6 + h
            if abs(wanted - state.expandedHeight) > 1 { state.expandedHeight = wanted }
        }
    }

    private func usageLine(_ title: String, _ window: UsageWindow) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.white.opacity(0.55))
            Text("\(Int(window.usedPercent))%").foregroundStyle(UsageStripView.levelColor(window.usedPercent))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .lineLimit(1)
    }

    /// Robots on the left wing (it widens as they arrive), the usage readout on the right wing.
    private func wings(height: CGFloat) -> some View {
        let botSize = state.botSize
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(state.bots) { bot in
                    BotView(bot: bot, paused: state.mode == .hidden)
                        .frame(width: botSize, height: botSize)
                        .contentShape(Rectangle())
                        .onTapGesture { state.onFocus(bot.id) }
                        .contextMenu { BotLookMenu(bot: bot, state: state) }
                        .help(bot.name)
                }
            }
            .padding(.trailing, 8)
            .frame(width: state.leftWingWidth, height: height, alignment: .trailing)
            Spacer().frame(width: state.geometry.notchWidth)
            Group {
                if let u = state.usage, u.fiveHour != nil || u.sevenDay != nil {
                    VStack(alignment: .trailing, spacing: 1) {
                        if let w = u.fiveHour { usageLine("5h", w) }
                        if let w = u.sevenDay { usageLine("7d", w) }
                    }
                } else {
                    Text("—").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: IslandState.rightWingWidth - 10, height: height, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .frame(height: height)
        .offset(x: state.mode == .expanded ? state.wingOffset : 0)
    }
}
