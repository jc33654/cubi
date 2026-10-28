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
                Text(bot.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(bot.ticker)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(bot.stateLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
    }
}
