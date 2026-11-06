import SwiftUI
import CubiKit

/// The settings window: a sidebar of sections on the left, one section's cards on the right.
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case claude, display, sleep, calendar, plugins, scope
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .display: "顯示"
            case .sleep: "睡眠"
            case .calendar: "行事曆"
            case .plugins: "插件"
            case .scope: "範圍"
            }
        }
        var icon: String {
            switch self {
            case .claude: "terminal"
            case .display: "macwindow"
            case .sleep: "moon"
            case .calendar: "calendar"
            case .plugins: "puzzlepiece.extension"
            case .scope: "folder.badge.minus"
            }
        }
    }

    @Bindable var hooks: HookSetupModel
    @Bindable var island: IslandState
    @Bindable var registry: PluginRegistry
    /// 系統通知 on or off (the window passes the Notifier's; an offline render, a constant).
    let notifications: Binding<Bool>
    let notificationsDenied: () async -> Bool
    let ignored: IgnoredDirectories
    @Bindable var timing: SleepTiming
    @Bindable var calendar: SystemCalendar
    let openTool: (String) -> Void
    @State var page: Page = .claude
    @State private var mascot: BotRuntime = {
        let b = BotRuntime(id: "settings", name: "Cubiii", color: RGB(hex: 0x3B82F6))
        b.shape = .gear
        return b
    }()
    @State private var calmDown: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Dash.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(page.title).font(.system(size: 22, weight: .bold))
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Dash.background)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { hooks.clearFeedback() }
        .onChange(of: page) { hooks.clearFeedback() }
        .environment(\.settingChanged, celebrate)
        .onChange(of: island.pinned) { celebrate() }
        .onChange(of: island.expandOnHover) { celebrate() }
        .onChange(of: island.botSizeChoice) { celebrate() }
        .onChange(of: timing.sleepMinutes) { celebrate() }
        .onChange(of: timing.restHours) { celebrate() }
        .onChange(of: calendar.calendarID) { celebrate() }
        .onChange(of: hooks.revision) { celebrate() }
        .sheet(item: Binding(get: { hooks.pending.map { PreviewBox(preview: $0) } }, set: { if $0 == nil { hooks.cancelPending() } })) { box in
            DiffSheet(title: hooks.pendingIsUninstall ? "解除安裝 Claude Code hooks" : "安裝 Claude Code hooks",
                      diff: box.preview.plan.diff, path: box.preview.url.path,
                      confirm: { hooks.confirmPending() }, cancel: { hooks.cancelPending() })
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BotView(bot: mascot, paused: false).frame(width: 34, height: 34)
                Text("Cubi").font(.system(size: 16, weight: .bold))
            }
            .padding(.horizontal, 6).padding(.bottom, 10)
            ForEach(Page.allCases) { s in
                Button { page = s } label: {
                    Label(s.title, systemImage: s.icon)
                        .font(.system(size: 13, weight: s == page ? .semibold : .regular))
                        .foregroundStyle(s == page ? Dash.accent : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(s == page ? Dash.accent.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 190)
        .background(Dash.sidebar)
    }

    /// A setting just changed: Cubiii is happy for a moment (again from the start on every change).
    private func celebrate() {
        mascot.model.setState(.happy)
        calmDown?.cancel()
        calmDown = Task {
            do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
            mascot.model.setState(.idle)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .claude: ClaudeSection(hooks: hooks)
        case .display: DisplaySection(island: island, notifications: notifications, notificationsDenied: notificationsDenied)
        case .sleep: SleepSection(timing: timing)
        case .calendar: CalendarSection(calendar: calendar)
        case .plugins: PluginsSection(registry: registry, hooks: hooks, openTool: openTool)
        case .scope: ScopeSection(ignored: ignored)
        }
    }
}
