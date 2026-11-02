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
                        .reportsExpandedHeight(to: state)
                } else {
                    VStack(spacing: 6) {
                        UsageStripView(usage: state.usage)
                        HStack(alignment: .top, spacing: 8) {
                            SessionListView(state: state, maxHeight: state.maxExpandedSize.height - state.compactHeight - 60)
                                .frame(width: state.selectedSession == nil ? nil : 300)
                            if let id = state.selectedSession, let bot = state.bots.first(where: { $0.id == id }) {
                                SessionDetailView(bot: bot, state: state).padding(.trailing, 14)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    .reportsExpandedHeight(to: state)
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
        .reportsExpandedHeight(to: state)
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
            HStack(spacing: IslandState.botSpacing) {
                ForEach(Array(state.activeBots.enumerated()), id: \.element.id) { index, bot in
                    let dragging = state.draggingBot == bot.id
                    BotView(bot: bot, paused: state.mode == .hidden)
                        .frame(width: botSize, height: botSize)
                        .contentShape(Rectangle())
                        .onTapGesture { state.onFocus(bot.id) }
                        .contextMenu { BotContextMenu(bot: bot, state: state) }
                        .help(bot.name)
                        // Rearranging: the robot follows the pointer, the others make room live.
                        // A drag that starts on a robot never moves the island (child gesture wins).
                        .offset(x: dragging ? state.dragCenterX - state.slotCenter(index) : 0)
                        .zIndex(dragging ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("wing"))
                            .onChanged { state.dragBot(bot.id, from: $0.startLocation.x, to: $0.location.x) }
                            .onEnded { _ in state.endDrag() })
                }
                .animation(.spring(duration: 0.2), value: state.bots.map(\.id))
                if !state.restingBots.isEmpty {
                    Text("💤 \(state.restingBots.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: IslandState.restingPillWidth, height: 18)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .contentShape(Capsule())
                        .onTapGesture { state.onExpand() }
                        .help("晚安區有 \(state.restingBots.count) 個 session")
                }
            }
            .coordinateSpace(name: "wing")
            .padding(.trailing, 8)
            .frame(width: state.leftWingWidth, height: height, alignment: .trailing)
            Spacer().frame(width: anchored ? state.geometry.notchWidth : IslandState.floatingGap)
            HStack(spacing: 8) {
                // New session, reachable the moment the island slides in (no need to expand it).
                Button { state.onNewSession(.dialog(fromSession: nil)) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("開新 session")
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

/// The expanded island is as tall as what it shows: the content takes its natural height and
/// reports it, no estimates.
private struct ReportsExpandedHeight: ViewModifier {
    let state: IslandState
    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                let wanted = state.compactHeight + 6 + h
                if abs(wanted - state.expandedHeight) > 1 { state.expandedHeight = wanted }
            }
    }
}

extension View {
    func reportsExpandedHeight(to state: IslandState) -> some View { modifier(ReportsExpandedHeight(state: state)) }
}
