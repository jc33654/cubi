import SwiftUI
import CubiKit

/// The tool plugins' sections at the bottom of a session's detail card, one per plugin with a
/// `session` hook. Each refreshes on its own clock only while it is on screen.
struct SessionWidgetView: View {
    let bot: BotRuntime
    @Bindable var state: IslandState
    let store: SessionWidgetStore

    var body: some View {
        ForEach(store.tools(), id: \.id) { tool in
            WidgetSection(bot: bot, tool: tool, state: state, store: store)
        }
    }
}

private struct WidgetSection: View {
    let bot: BotRuntime
    let tool: ToolPlugin
    @Bindable var state: IslandState
    let store: SessionWidgetStore

    private var entry: SessionWidgetStore.Entry? { store.entry(session: bot.id, plugin: tool.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry?.output?.title ?? tool.displayName).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                if entry?.loading == true { ProgressView().controlSize(.mini).scaleEffect(0.6) }
            }
            .padding(.top, 4)
            if let failure = entry?.failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.red.opacity(0.85)).lineLimit(2)
            } else if let out = entry?.output {
                if let error = out.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red.opacity(0.85)).lineLimit(2)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(Array(out.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            if let url = row.url.flatMap(URL.init(string:)) {
                                Button { NSWorkspace.shared.open(url) } label: {
                                    Text(row.label + " ↗").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).underline()
                                }
                                .buttonStyle(.plain)
                                .help(url.absoluteString)
                                .frame(width: 72, alignment: .leading)
                            } else {
                                Text(row.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).frame(width: 72, alignment: .leading)
                            }
                            WidgetValue(row: row)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(Array((entry?.output?.actions ?? []).enumerated()), id: \.offset) { _, action in
                    if let symbol = action.icon, IconButton.exists(symbol) {
                        IconButton(symbol: symbol, label: action.label) { Task { await store.act(action, session: bot.id, plugin: tool) } }
                    } else {
                        CardButton(title: action.label, role: .quiet) { Task { await store.act(action, session: bot.id, plugin: tool) } }
                    }
                }
                IconButton(symbol: "rectangle.on.rectangle", label: "開 \(tool.displayName) 面板") { state.onOpenTool(tool.id, bot.id) }
            }
        }
        // SwiftUI cancels this when the card leaves the screen (another session, island collapsed).
        .task(id: "\(bot.id)|\(tool.id)|\(tool.session?.refresh ?? 0)") {
            let every = tool.session?.refresh ?? 60
            while !Task.isCancelled {
                await store.refresh(session: bot.id, plugin: tool)
                try? await Task.sleep(for: .seconds(every))
            }
        }
    }
}

/// A row's value: coloured by its tone, ticking when it has a clock, a thin bar under it for progress.
private struct WidgetValue: View {
    let row: PluginIO.WidgetOutput.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let tone = row.tone { Circle().fill(StatusStyle.color(tone)).frame(width: 6, height: 6) }
                if let clock = row.clock {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        let secs = clock.seconds(at: tl.date.timeIntervalSince1970)
                        Text(StatusStyle.reading(secs, down: clock.down)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(secs < 0 ? StatusStyle.danger : color)
                    }
                    if !row.value.isEmpty { text(row.value).foregroundStyle(.white.opacity(0.6)) }
                } else {
                    text(row.value).foregroundStyle(color)
                }
            }
            if let p = row.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10))
                        Capsule().fill(row.tone.map(StatusStyle.color) ?? StatusStyle.info).frame(width: geo.size.width * p)
                    }
                }
                .frame(width: 140, height: 4)
            }
        }
    }

    private var color: Color { row.tone.map(StatusStyle.color) ?? .white.opacity(0.85) }

    private func text(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }
}
