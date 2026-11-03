import SwiftUI
import AppKit
import CubiKit

/// Settings → 插件: agents (one row per plugin; Claude Code is built in, others come from
/// manifests) and tools (HTML panels with a command whitelist).
struct PluginsSection: View {
    @Bindable var registry: PluginRegistry
    @Bindable var hooks: HookSetupModel
    let openTool: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("插件").font(.headline)
                Spacer()
                Button("重新載入") { registry.reload() }
                Button("開啟 plugins 目錄") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: PluginRegistry.pluginsDirectory.path)
                }
            }
            Text("放一份 manifest.json 到 plugins/<id>/ 就能新增（範例在 repo 的 docs/plugins/）。Agents 預設關閉；工具預設開啟。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Agents").font(.system(size: 12, weight: .semibold))
            ForEach(registry.plugins, id: \.id) { plugin in
                PluginRow(plugin: plugin, registry: registry, hooks: hooks)
            }
            Text("工具").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            if registry.tools.isEmpty {
                Text("沒有工具插件。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(registry.tools, id: \.id) { tool in
                ToolRow(tool: tool, registry: registry, openTool: openTool)
            }
            ForEach(Array(registry.loadErrors.keys.sorted()), id: \.self) { dir in
                Label("\(dir)：\(registry.loadErrors[dir] ?? "")", systemImage: "xmark.octagon")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }
}

private struct ToolRow: View {
    let tool: ToolPlugin
    @Bindable var registry: PluginRegistry
    let openTool: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { registry.isEnabled(tool.id) }, set: { registry.setEnabled(tool.id, $0) })) {
                HStack(spacing: 6) {
                    Text(tool.displayName).font(.system(size: 12, weight: .semibold))
                    Text(tool.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(tool.panel.file).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
            Button("開啟") { openTool(tool.id) }.disabled(!registry.isEnabled(tool.id))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct PluginRow: View {
    let plugin: any AgentPlugin
    @Bindable var registry: PluginRegistry
    @Bindable var hooks: HookSetupModel
    @State private var secretValues: [String: String] = [:]
    @State private var status: ClaudeHookInstaller.Status?

    private var enabled: Binding<Bool> {
        Binding(get: { registry.isEnabled(plugin.id) }, set: { registry.setEnabled(plugin.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: plugin.accentColor.r, green: plugin.accentColor.g, blue: plugin.accentColor.b))
                    .frame(width: 12, height: 12)
                Toggle(isOn: enabled) {
                    HStack(spacing: 6) {
                        Text(plugin.displayName).font(.system(size: 12, weight: .semibold))
                        Text(plugin.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        if plugin.isBuiltIn { tag("內建") }
                        if plugin.capabilities.contains(.approvals) { tag("審批") }
                        if plugin.capabilities.contains(.questions) { tag("問題") }
                        if plugin.capabilities.contains(.statusline) { tag("用量") }
                    }
                }
                Spacer()
                installControls
            }
            if plugin.id != ClaudeCodePlugin.agentID, !plugin.secrets.isEmpty {
                ForEach(plugin.secrets, id: \.key) { spec in
                    HStack {
                        Text(spec.label + (spec.required ? "（必填）" : "")).font(.system(size: 11)).frame(width: 140, alignment: .leading)
                        SecureField("存在登入鑰匙圈", text: Binding(
                            get: { secretValues[spec.key] ?? registry.secret(plugin.id, spec.key) ?? "" },
                            set: { secretValues[spec.key] = $0 }))
                            .font(.system(size: 11, design: .monospaced))
                        Button("儲存") { registry.setSecret(plugin.id, spec.key, secretValues[spec.key] ?? "") }
                            .disabled(secretValues[spec.key] == nil)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .onAppear { status = try? HookSetup.status(plugin: plugin) }
    }

    @ViewBuilder
    private var installControls: some View {
        switch plugin.installMode {
        case .jsonHooks(let file):
            if plugin.id == ClaudeCodePlugin.agentID {
                Text("上方 Claude Code 區塊管理").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text((status?.hooksInstalled ?? false) ? "已裝到 \(file)" : file)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Button((status?.hooksInstalled ?? false) ? "更新…" : "安裝…") { hooks.previewInstall(plugin: plugin) }
                    if status?.hooksInstalled ?? false { Button("解除…") { hooks.previewUninstall(plugin: plugin) } }
                }
            }
        case .manual(let instructions):
            Text(instructions.isEmpty ? "手動安裝" : instructions).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
