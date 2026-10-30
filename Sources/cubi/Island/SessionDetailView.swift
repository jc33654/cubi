import SwiftUI
import CubiKit

/// The right column of the expanded island when a session row is selected.
struct SessionDetailView: View {
    let bot: BotRuntime
    @Bindable var state: IslandState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ShapeSwatch(shape: bot.shape, color: bot.color, size: 14)
                Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(bot.stateLabel).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                CardButton(title: "跳到終端", role: .secondary) { state.onFocus(bot.id) }
                Button { state.selectedSession = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            Text(bot.ticker).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                if let p = bot.stats.projectDir ?? bot.cwd { row("專案", SessionDetail.home(p), mono: true) }
                if let c = bot.stats.currentDir ?? bot.cwd, c != (bot.stats.projectDir ?? bot.cwd) { row("目前目錄", SessionDetail.home(c), mono: true) }
                if let m = bot.stats.modelDisplayName ?? bot.modelName {
                    row("模型", [m, bot.stats.effort.map { "effort \($0)" }, bot.stats.version.map { "Claude Code \($0)" }].compactMap { $0 }.joined(separator: " · "))
                }
                let start = SessionDetail.start(bot)
                row("開始", start.map { SessionDetail.time($0.date) + ($0.approximate ? "（Cubi 看到起）" : "") } ?? "—")
                GridRow {
                    label("使用時間")
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        let api = bot.stats.apiDurationMS.map { "，API \(SessionDetail.duration($0 / 1000))" } ?? ""
                        value(SessionDetail.elapsed(bot, now: tl.date).map { SessionDetail.duration($0) + api } ?? "—")
                    }
                }
                row("回合", "\(bot.prompts) 次，工具呼叫 \(bot.toolCalls) 次" + (start?.approximate == false ? "（Cubi 看到起）" : ""))
                if let cost = bot.costUSD { row("花費", String(format: "$%.2f", cost)) }
                if bot.stats.linesAdded != nil || bot.stats.linesRemoved != nil || bot.lastEdit != nil {
                    GridRow {
                        label("變更")
                        HStack(spacing: 6) {
                            if let a = bot.stats.linesAdded, let r = bot.stats.linesRemoved {
                                Text("+\(a) −\(r)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                            }
                            if let edit = bot.lastEdit {
                                Button { state.showingDiffFor = bot.id } label: {
                                    Text("\(edit.path.split(separator: "/").last.map(String.init) ?? edit.path)  +\(edit.added) −\(edit.removed)")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(.white.opacity(0.14)))
                                }
                                .buttonStyle(.plain)
                                .help(edit.path)
                            }
                        }
                    }
                }
                GridRow {
                    label("Context")
                    HStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12))
                                Capsule().fill(UsageStripView.levelColor(bot.contextPercent)).frame(width: geo.size.width * min(100, bot.contextPercent) / 100)
                            }
                        }
                        .frame(width: 90, height: 6)
                        Text("\(Int(bot.contextPercent))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                if let t = SessionDetail.terminal(bot.client) { row("終端", t, mono: true) }
                row("session", String(bot.id.prefix(8)), mono: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func row(_ title: String, _ text: String, mono: Bool = false) -> some View {
        GridRow {
            label(title)
            value(text, mono: mono)
        }
    }

    private func value(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, design: mono ? .monospaced : .default))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).frame(width: 56, alignment: .leading)
    }
}
