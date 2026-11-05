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
                    .help(identity)
                    .contextMenu {
                        Button("複製 session id") { copy(bot.id) }
                        if let t = SessionDetail.terminal(bot.client) { Button("複製終端：\(t)") { copy(t) } }
                    }
                StateChip(label: bot.stateLabel, resting: bot.resting)
                Spacer()
                IconButton(symbol: "plus.square.on.square", label: "在這個專案再開一個 session") { state.onNewSession(.dialog(fromSession: bot.id)) }
                IconButton(symbol: bot.resting ? "sun.max" : "moon", label: bot.resting ? "起床上班" : "去睡覺") { state.onSessionAction(bot.resting ? .wake : .rest, bot.id) }
                IconButton(symbol: "eye.slash", label: "放生（從島上拿掉，要你的時候再回來）") { state.onSessionAction(.dismiss, bot.id) }
                IconButton(symbol: "arrow.up.forward.app", label: "跳到終端", tint: StatusStyle.info) { state.onFocus(bot.id) }
                IconButton(symbol: "xmark", label: "關閉") { state.selectedSession = nil }
            }
            Text(bot.ticker).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                let project = bot.stats.projectDir ?? bot.cwd, current = bot.stats.currentDir ?? bot.cwd
                if let project, let current, current != project {
                    row("專案", SessionDetail.home(project) + "  →  " + SessionDetail.home(current), mono: true)
                } else if let project {
                    row("專案", SessionDetail.home(project), mono: true)
                } else if let current {
                    row("目前目錄", SessionDetail.home(current), mono: true)
                }
                if let m = bot.stats.modelDisplayName ?? bot.modelName {
                    row("模型", [m, bot.stats.effort.map { "effort \($0)" }, bot.stats.version.map { "Claude Code \($0)" }].compactMap { $0 }.joined(separator: " · "))
                }
                let start = SessionDetail.start(bot)
                GridRow {
                    label("時間")
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        // ≈: Cubi only saw the session from then (counts below likewise start there).
                        let since = start.map { ($0.approximate ? "≈" : "") + SessionDetail.time($0.date) + " 起" } ?? "—"
                        let used = SessionDetail.elapsed(bot, now: tl.date).map { " · " + SessionDetail.duration($0) } ?? ""
                        let api = bot.stats.apiDurationMS.map { "（API \(SessionDetail.duration($0 / 1000))）" } ?? ""
                        value(since + used + api)
                    }
                    .help(start?.approximate == true ? "Cubi 看到它之後才開始算（session 更早就開了）" : "")
                }
                GridRow {
                    label("回合")
                    HStack(spacing: 6) {
                        // Counted only from when Cubi saw the session: ≈ when the transcript is clearly older.
                        let partial = bot.transcriptCreatedAt.map { bot.startedAt - $0.timeIntervalSinceReferenceDate > 10 } ?? false
                        value((partial ? "≈" : "") + "\(bot.prompts) · 工具 \(bot.toolCalls)" + (bot.costUSD.map { String(format: " · $%.2f", $0) } ?? ""))
                            .help(partial ? "回合與工具次數只算 Cubi 看到之後（session 更早就開了）" : "")
                        if let a = bot.stats.linesAdded, let r = bot.stats.linesRemoved {
                            Text("+\(a)").font(.system(size: 11, design: .monospaced)).foregroundStyle(StatusStyle.good)
                            Text("−\(r)").font(.system(size: 11, design: .monospaced)).foregroundStyle(StatusStyle.danger)
                        }
                        if let edit = bot.lastEdit {
                            Button { state.showingDiffFor = bot.id } label: {
                                Text(edit.path.split(separator: "/").last.map(String.init) ?? edit.path)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(.white.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .help("看最近一次修改的 diff：\(edit.path)  +\(edit.added) −\(edit.removed)")
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
                        Text("\(Int(bot.contextPercent))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(UsageStripView.levelColor(bot.contextPercent))
                    }
                }
            }
            if let widgets = state.widgets { SessionWidgetView(bot: bot, state: state, store: widgets) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Terminal and session id: rarely needed, so they live in the name's tooltip (and its right-click menu).
    private var identity: String {
        ([SessionDetail.terminal(bot.client), "session " + String(bot.id.prefix(8))] as [String?]).compactMap { $0 }.joined(separator: "\n")
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
