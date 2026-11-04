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
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
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
                            Text(row.value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(Array((entry?.output?.actions ?? []).enumerated()), id: \.offset) { _, action in
                    CardButton(title: action.label, role: .quiet) {
                        Task { await store.act(action.action, session: bot.id, plugin: tool) }
                    }
                }
                CardButton(title: "開面板", role: .secondary) { state.onOpenTool(tool.id, bot.id) }
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
