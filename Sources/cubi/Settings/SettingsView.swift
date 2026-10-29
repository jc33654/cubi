import SwiftUI
import ServiceManagement
import CubiKit

struct SettingsView: View {
    @Bindable var hooks: HookSetupModel
    @Bindable var island: IslandState
    let notifier: Notifier
    let ignored: IgnoredDirectories
    let openToolkit: () -> Void

    @State private var soundsOn = Sounds.enabled
    @State private var notificationsOn = false
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var ignoredText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                claudeSection
                Divider()
                displaySection
                Divider()
                scopeSection
                if FileManager.default.fileExists(atPath: ToolkitPanel.htmlPath) {
                    Divider()
                    toolkitSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            hooks.refresh()
            notificationsOn = notifier.enabled
            ignoredText = ignored.prefixes.joined(separator: "\n")
        }
        .sheet(item: Binding(get: { hooks.pending.map { PreviewBox(preview: $0) } }, set: { if $0 == nil { hooks.cancelPending() } })) { box in
            DiffSheet(title: hooks.pendingIsUninstall ? "解除安裝 Claude Code hooks" : "安裝 Claude Code hooks",
                      diff: box.preview.plan.diff, path: HookSetup.settingsURL.path,
                      confirm: { hooks.confirmPending() }, cancel: { hooks.cancelPending() })
        }
    }

    // MARK: Claude Code

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code").font(.headline)
            if let s = hooks.status {
                statusRow("Hooks", ok: s.hooksInstalled, okText: "已安裝（所有目錄的 session 都會有機器人）", noText: "未安裝（只有專案自己設定的目錄會有）")
                statusRow("Status line", ok: s.statuslineChained, okText: "已串接（用量與 context % 會進來）", noText: "未串接")
                if !s.legacyNotificationCommands.isEmpty {
                    Toggle("同時移除舊的桌面通知 hook（\(s.legacyNotificationCommands.joined(separator: ", "))），改用 Cubi 的通知", isOn: $hooks.retireLegacyNotification)
                        .font(.system(size: 12))
                }
                HStack {
                    Button(s.hooksInstalled ? "重新安裝 / 更新" : "安裝…") { hooks.previewInstall() }
                    if s.hooksInstalled || s.statuslineChained {
                        Button("解除安裝…") { hooks.previewUninstall() }
                    }
                    Spacer()
                    Text(HookSetup.settingsURL.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if hooks.needsRestart {
                Label("hooks 是 session 啟動時讀的：已開著的 Claude Code 要重開才會生效。", systemImage: "arrow.clockwise")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            if !hooks.projectLocalFiles.isEmpty {
                ForEach(hooks.projectLocalFiles, id: \.path) { url in
                    HStack {
                        Label("開發期間留下的專案 hooks：\(url.path)。全域 hooks 裝好後這裡會重複觸發。", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                        Spacer()
                        Button("移除") { hooks.stripProjectLocal(url) }
                    }
                }
            }
            if let m = hooks.message { Text(m).font(.system(size: 12)).foregroundStyle(.secondary) }
            if let e = hooks.error { Text(e).font(.system(size: 12)).foregroundStyle(.red) }
        }
    }

    private func statusRow(_ title: String, ok: Bool, okText: String, noText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            Text(title).frame(width: 80, alignment: .leading)
            Text(ok ? okText : noText).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    // MARK: Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("顯示").font(.headline)
            Toggle("保持顯示（島不收回，休息時停在 compact）", isOn: $island.pinned)
            Toggle("音效", isOn: $soundsOn).onChange(of: soundsOn) { _, v in Sounds.enabled = v }
            Toggle("系統通知（需要權限、預設關）", isOn: $notificationsOn).onChange(of: notificationsOn) { _, v in notifier.enabled = v }
            Toggle("登入時啟動", isOn: $loginOn).onChange(of: loginOn) { _, v in
                do { v ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                catch { CubiLog.write("login item: \(error)") }
                loginOn = SMAppService.mainApp.status == .enabled
            }
        }
        .font(.system(size: 12))
    }

    // MARK: Scope

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("範圍").font(.headline)
            Text("忽略這些目錄開頭的 session（一行一個，可用 ~）").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $ignoredText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .onChange(of: ignoredText) { _, v in ignored.prefixes = v.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
    }

    // MARK: Toolkit

    private var toolkitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工具箱").font(.headline)
            HStack {
                Button("開啟 Claude Toolkit 面板") { openToolkit() }
                Text("原本 ClaudeToolkit.app 的管理面板，直接搬進來。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PreviewBox: Identifiable {
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
