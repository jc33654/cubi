import SwiftUI
import AppKit
import CubiKit

/// Settings → 插件: one card per plugin. Agents (Claude Code built in, others from manifests) and
/// tools (HTML panels with a command whitelist), with what each one hooks into.
struct PluginsSection: View {
    @Bindable var registry: PluginRegistry
    @Bindable var hooks: HookSetupModel
    let openTool: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("放一份 manifest.json 到 plugins/<id>/ 就能新增").foregroundStyle(.secondary)
                InfoTip(text: "範例在 repo 的 docs/plugins/。Agents 預設關閉；工具預設開啟。")
                Spacer()
                Button { registry.reload() } label: { Label("重新載入", systemImage: "arrow.clockwise") }
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: PluginRegistry.pluginsDirectory.path)
                } label: { Label("plugins 目錄", systemImage: "folder") }
            }
            .font(.system(size: 12))
            HookFeedback(hooks: hooks).font(.system(size: 12))
            groupTitle("工具")
            if registry.tools.isEmpty { Text("沒有工具插件。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(registry.tools, id: \.id) { ToolCard(tool: $0, registry: registry, openTool: openTool) }
            groupTitle("Agents")
            ForEach(registry.plugins, id: \.id) { AgentCard(plugin: $0, registry: registry, hooks: hooks) }
            ForEach(Array(registry.loadErrors.keys.sorted()), id: \.self) { dir in
                Label("\(dir)：\(registry.loadErrors[dir] ?? "")", systemImage: "xmark.octagon")
                    .font(.system(size: 11)).foregroundStyle(Dash.danger)
            }
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }
}

private struct ToolCard: View {
    let tool: ToolPlugin
    @Bindable var registry: PluginRegistry
    let openTool: (String) -> Void
    @Environment(\.settingChanged) private var settingChanged

    var body: some View {
        DashCard(title: tool.displayName, icon: "puzzlepiece.extension", help: "\(tool.id) · \(tool.directory)") {
            Button("開啟") { openTool(tool.id) }.disabled(!registry.isEnabled(tool.id))
            switchToggle(Binding(get: { registry.isEnabled(tool.id) }, set: { registry.setEnabled(tool.id, $0); settingChanged() }))
        } content: {
            HStack(spacing: 6) {
                if tool.session != nil { TraitTag(text: "資訊窗") }
                if tool.tick != nil { TraitTag(text: "定時") }
                if tool.panel.style == .cubi { TraitTag(text: "樣式包") }
            }
        }
    }
}

private struct AgentCard: View {
    let plugin: any AgentPlugin
    @Bindable var registry: PluginRegistry
    @Bindable var hooks: HookSetupModel
    @State private var secretValues: [String: String] = [:]
    @State private var status: ClaudeHookInstaller.Status?
    @State private var readProblem: String?
    @State private var keychainProblem: String?
    @Environment(\.settingChanged) private var settingChanged

    var body: some View {
        DashCard(title: plugin.displayName, icon: "cpu", help: plugin.id) {
            installControls
            switchToggle(Binding(get: { registry.isEnabled(plugin.id) }, set: { registry.setEnabled(plugin.id, $0); settingChanged() }))
        } content: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: plugin.accentColor.r, green: plugin.accentColor.g, blue: plugin.accentColor.b))
                    .frame(width: 10, height: 10)
                if plugin.isBuiltIn { TraitTag(text: "內建") }
                if plugin.capabilities.contains(.approvals) { TraitTag(text: "審批") }
                if plugin.capabilities.contains(.questions) { TraitTag(text: "問題") }
                if plugin.capabilities.contains(.statusline) { TraitTag(text: "用量") }
            }
            ForEach([readProblem, keychainProblem].compactMap { $0 }, id: \.self) { Text($0).foregroundStyle(Dash.danger) }
            if plugin.id != ClaudeCodePlugin.agentID {
                ForEach(plugin.secrets, id: \.key) { spec in
                    SettingRow(title: spec.label + (spec.required ? "（必填）" : ""), help: "存在登入鑰匙圈") {
                        SecureField("", text: Binding(
                            get: { secretValues[spec.key] ?? registry.secret(plugin.id, spec.key) ?? "" },
                            set: { secretValues[spec.key] = $0 }))
                            .font(.system(size: 11, design: .monospaced)).frame(width: 220)
                        Button("儲存") {
                            if registry.setSecret(plugin.id, spec.key, secretValues[spec.key] ?? "") { keychainProblem = nil; settingChanged() }
                            else { keychainProblem = "存不進登入鑰匙圈" }
                        }
                            .disabled(secretValues[spec.key] == nil)
                    }
                }
            }
        }
        .task(id: hooks.revision) {
            // Claude Code's file is read (and its error shown) by the page's own feedback line.
            guard plugin.id != ClaudeCodePlugin.agentID else { return }
            do { status = try HookSetup.status(plugin: plugin); readProblem = nil }
            catch { status = nil; readProblem = "讀不到安裝狀態：\(error.localizedDescription)" }
        }
    }

    @ViewBuilder
    private var installControls: some View {
        switch plugin.installMode {
        case .jsonHooks(let file):
            if plugin.id == ClaudeCodePlugin.agentID {
                Text("在 Claude Code 頁管理").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let installed = status?.hooksInstalled ?? false
                if installed { Button("解除…") { hooks.previewUninstall(plugin: plugin) } }
                Button(installed ? "更新…" : "安裝…") { hooks.previewInstall(plugin: plugin) }.help(file)
            }
        case .manual(let instructions):
            Text(instructions.isEmpty ? "手動安裝" : instructions).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
