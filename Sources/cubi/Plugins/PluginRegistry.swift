import Foundation
import Observation
import CubiKit

/// Built-in plugins plus manifests from ~/Library/Application Support/cubi/plugins/<id>/manifest.json.
/// A manifest with `"kind": "tool"` is a tool plugin (an HTML panel); anything else is an agent.
/// Agents are off by default except Claude Code (a disabled agent's events are dropped); tools are
/// on by default, since they only run when the user opens them.
@MainActor
@Observable
final class PluginRegistry {
    static let enabledKey = "enabledPlugins"
    static var pluginsDirectory: URL {
        CubiPaths.home.appendingPathComponent("Library/Application Support/cubi/plugins")
    }

    private(set) var plugins: [any AgentPlugin] = []
    private(set) var tools: [ToolPlugin] = []
    /// Why a folder's manifest was refused, by folder name.
    private(set) var loadErrors: [String: String] = [:]
    /// Keys no parser reads in a manifest that did load (likely typos), by folder name.
    private(set) var loadWarnings: [String: [String]] = [:]
    /// What `PluginServices` last said about each plugin's background service, for the settings page.
    var serviceStatus: [String: PluginServices.Status] = [:]
    /// Called after a reload and when a switch changes; `PluginServices` starts and stops services on it.
    @ObservationIgnored var onChange: (() -> Void)?

    init() { reload() }

    func reload() {
        var list: [any AgentPlugin] = [ClaudeCodePlugin()]
        var toolList: [ToolPlugin] = []
        var errors: [String: String] = [:]
        var warnings: [String: [String]] = [:]
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dirs = (try? fm.contentsOfDirectory(at: Self.pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let folder = dir.lastPathComponent
            guard fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else { continue }
            do {
                let loaded = try PluginManifest.load(directory: dir, home: CubiPaths.home.path)
                // One namespace for both kinds: the id is also what the menu, the defaults and the relay
                // key off. Folder names are ids, so only a folder named after a built-in can clash.
                let id = loaded.plugin.id
                if list.contains(where: { $0.id == id }) || toolList.contains(where: { $0.id == id }) {
                    errors[folder] = "id「\(id)」已存在"
                    continue
                }
                switch loaded.plugin {
                case .tool(let tool): toolList.append(tool)
                case .agent(let agent): list.append(agent)
                }
                if !loaded.warnings.isEmpty { warnings[folder] = loaded.warnings }
            } catch {
                errors[folder] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        plugins = list
        tools = toolList
        loadErrors = errors
        loadWarnings = warnings
        let names = list.map { "\($0.id)\(isEnabled($0.id) ? "" : "(off)")" } + toolList.map { "\($0.id)(tool\(isEnabled($0.id) ? "" : ", off"))" }
        CubiLog.write("plugins: \(names.joined(separator: ", "))")
        for (folder, why) in errors.sorted(by: { $0.key < $1.key }) { CubiLog.write("plugin \(folder) rejected: \(why)") }
        for (folder, list) in warnings.sorted(by: { $0.key < $1.key }) { CubiLog.write("plugin \(folder) warning: \(list.joined(separator: "；"))") }
        onChange?()
    }

    func plugin(for agent: String) -> (any AgentPlugin)? {
        plugins.first { $0.id == agent }
    }

    /// The user's switches, kept here (not only in UserDefaults) so views reading `isEnabled` redraw.
    private var enabled = UserDefaults.standard.dictionary(forKey: PluginRegistry.enabledKey) as? [String: Bool] ?? [:]

    func isEnabled(_ id: String) -> Bool {
        enabled[id] ?? (id == ClaudeCodePlugin.agentID || tools.contains { $0.id == id })
    }

    func setEnabled(_ id: String, _ on: Bool) {
        enabled[id] = on
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        CubiLog.write("plugin \(id) \(on ? "enabled" : "disabled")")
        // Observers key off `plugins`; nudge them.
        plugins = plugins
        onChange?()
    }

    // MARK: Background services

    static let servicesKey = "enabledServices"
    /// Off unless the user turns it on: a service runs all the time and may listen on the network.
    private var servicesOn = UserDefaults.standard.dictionary(forKey: PluginRegistry.servicesKey) as? [String: Bool] ?? [:]

    func isServiceOn(_ id: String) -> Bool { servicesOn[id] ?? false }

    func setServiceOn(_ id: String, _ on: Bool) {
        servicesOn[id] = on
        UserDefaults.standard.set(servicesOn, forKey: Self.servicesKey)
        CubiLog.write("plugin \(id) service \(on ? "on" : "off")")
        onChange?()
    }

    // MARK: Secrets

    func secret(_ plugin: String, _ key: String) -> String? { Keychain.get(plugin: plugin, key: key) }

    /// Whether the keychain took it.
    func setSecret(_ plugin: String, _ key: String, _ value: String) -> Bool {
        value.isEmpty ? Keychain.remove(plugin: plugin, key: key) : Keychain.set(plugin: plugin, key: key, value: value)
    }
}
