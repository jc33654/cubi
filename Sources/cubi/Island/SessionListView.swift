import SwiftUI
import CubiKit

/// Expanded island: one row per session with its colour, name, state and ticker.
struct SessionListView: View {
    @Bindable var state: IslandState

    var body: some View {
        if state.bots.isEmpty {
            Text("沒有 Claude Code session")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(state.bots) { bot in row(bot) }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private func row(_ bot: BotRuntime) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(BotPainter.swift(bot.color))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(bot.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if bot.agent != "claude-code" {
                        Text(bot.agent)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                }
                Text(bot.ticker)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let edit = bot.lastEdit {
                Button { state.showingDiffFor = bot.id } label: {
                    Text("+\(edit.added) −\(edit.removed)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help(edit.path)
            }
            if bot.contextPercent > 0 {
                Text("ctx \(Int(bot.contextPercent))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(UsageStripView.levelColor(bot.contextPercent).opacity(0.9))
            }
            Text(bot.stateLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { state.onFocus(bot.id) }
    }
}
