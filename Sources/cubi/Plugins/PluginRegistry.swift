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
    private(set) var loadErrors: [String: String] = [:]

    init() { reload() }

    func reload() {
        var list: [any AgentPlugin] = [ClaudeCodePlugin()]
        var toolList: [ToolPlugin] = []
        var errors: [String: String] = [:]
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dirs = (try? fm.contentsOfDirectory(at: Self.pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifest.path) else { continue }
            do {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: manifest))
                // One namespace for both kinds: the id is also what the menu, the defaults and the relay key off.
                func taken(_ id: String) -> Bool { list.contains { $0.id == id } || toolList.contains { $0.id == id } }
                if value["kind"]?.string == "tool" {
                    let tool = try ToolPlugin.parse(value, baseDirectory: dir.path, home: CubiPaths.home.path)
                    if taken(tool.id) { errors[dir.lastPathComponent] = "id「\(tool.id)」已存在" } else { toolList.append(tool) }
                } else {
                    let agent = try ManifestPlugin.parse(value)
                    if taken(agent.id) { errors[dir.lastPathComponent] = "id「\(agent.id)」已存在" } else { list.append(agent) }
                }
            } catch {
                errors[dir.lastPathComponent] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        plugins = list
        tools = toolList
        loadErrors = errors
        let names = list.map { "\($0.id)\(isEnabled($0.id) ? "" : "(off)")" } + toolList.map { "\($0.id)(tool\(isEnabled($0.id) ? "" : ", off"))" }
        CubiLog.write("plugins: \(names.joined(separator: ", "))")
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
    }

    // MARK: Secrets

    func secret(_ plugin: String, _ key: String) -> String? { Keychain.get(plugin: plugin, key: key) }

    /// Whether the keychain took it.
    func setSecret(_ plugin: String, _ key: String, _ value: String) -> Bool {
        value.isEmpty ? Keychain.remove(plugin: plugin, key: key) : Keychain.set(plugin: plugin, key: key, value: value)
    }
}
