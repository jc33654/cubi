import SwiftUI
import CubiKit

/// What the island shows: the robot row with the usage readout, and below it (when expanded) a
/// card, a diff, or the session list. Shared by the notch island and the floating window.
struct IslandContent: View {
    @Bindable var state: IslandState
    /// Notch island: keep a gap for the notch and centre the row on it. Floating: no gap.
    var anchored: Bool

    var body: some View {
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
            Spacer().frame(width: anchored ? state.geometry.notchWidth : IslandState.floatingGap)
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
        .offset(x: anchored && state.mode == .expanded ? state.wingOffset : 0)
    }
}
