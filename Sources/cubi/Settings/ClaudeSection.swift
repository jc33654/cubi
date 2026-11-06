import SwiftUI
import CubiKit

/// Settings → Claude Code: the global hooks and the status line chain.
struct ClaudeSection: View {
    @Bindable var hooks: HookSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashCard(title: "Hooks 與 status line", icon: "link",
                     help: "Hooks 讓所有目錄的 session 都有機器人；status line 帶進用量與 context %。寫入前會先備份並給你看差異。") {
                if let s = hooks.status {
                    if s.hooksInstalled || s.statuslineChained { Button("解除安裝…") { hooks.previewUninstall() } }
                    Button(s.hooksInstalled ? "重新安裝" : "安裝…") { hooks.previewInstall() }
                        .buttonStyle(.borderedProminent).tint(Dash.accent)
                }
            } content: {
                if let s = hooks.status {
                    SettingRow(title: "Hooks", help: "未安裝時只有專案自己設定的目錄會有機器人") {
                        StatusPill(text: s.hooksInstalled ? "已安裝" : "未安裝", tone: s.hooksInstalled ? .good : .warning)
                    }
                    SettingRow(title: "Status line") {
                        StatusPill(text: s.statuslineChained ? "已串接" : "未串接", tone: s.statuslineChained ? .good : .neutral)
                    }
                    if !s.legacyNotificationCommands.isEmpty {
                        SettingRow(title: "改用 Cubi 的通知", help: "安裝時一併移除舊的桌面通知 hook：\(s.legacyNotificationCommands.joined(separator: ", "))") {
                            switchToggle($hooks.retireLegacyNotification)
                        }
                    }
                    Text(HookSetup.settingsURL.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                HookFeedback(hooks: hooks)
            }
            if !hooks.projectLocalFiles.isEmpty {
                DashCard(title: "開發期間留下的專案 hooks", icon: "exclamationmark.triangle",
                         help: "全域 hooks 裝好後，這些專案設定會讓事件重複觸發。") {
                    ForEach(hooks.projectLocalFiles, id: \.path) { url in
                        SettingRow(title: url.path) { Button("移除") { hooks.stripProjectLocal(url) } }
                    }
                }
            }
        }
    }
}

/// What the last install or uninstall said; shown wherever it can be started from.
struct HookFeedback: View {
    let hooks: HookSetupModel

    var body: some View {
        if hooks.needsRestart {
            Label("已開著的 session 要重開才會生效", systemImage: "arrow.clockwise").foregroundStyle(Dash.warning)
        }
        if let m = hooks.message { Text(m).foregroundStyle(.secondary) }
        if let e = hooks.readError { Text(e).foregroundStyle(Dash.danger) }
        if let e = hooks.error { Text(e).foregroundStyle(Dash.danger) }
    }
}

struct PreviewBox: Identifiable {
    let preview: HookSetup.Preview
    var id: String { String(preview.plan.diff.hashValue) }
}

/// Backup, diff, confirm: nothing is written until the button is pressed.
struct DiffSheet: View {
    let title: String
    let diff: String
    let path: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text("要寫入 \(path)。寫入前會先備份到 ~/.claude/backups/cubi/。只有下面這些行會變：")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("+") ? .green : (line.hasPrefix("-") ? .red : .primary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("寫入", action: confirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
    }
}
