import Foundation
import Observation
import CubiKit

/// Built-in plugins plus manifests from ~/Library/Application Support/cubi/plugins/<id>/manifest.json.
/// Every plugin is off by default except Claude Code; a disabled plugin's events are dropped.
@MainActor
@Observable
final class PluginRegistry {
    static let enabledKey = "enabledPlugins"
    static var pluginsDirectory: URL {
        CubiPaths.home.appendingPathComponent("Library/Application Support/cubi/plugins")
    }

    private(set) var plugins: [any AgentPlugin] = []
    private(set) var loadErrors: [String: String] = [:]

    init() { reload() }

    func reload() {
        var list: [any AgentPlugin] = [ClaudeCodePlugin()]
        var errors: [String: String] = [:]
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dirs = (try? fm.contentsOfDirectory(at: Self.pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifest.path) else { continue }
            do {
                let plugin = try ManifestPlugin.load(url: manifest)
                if list.contains(where: { $0.id == plugin.id }) {
                    errors[dir.lastPathComponent] = "id「\(plugin.id)」已存在"
                } else {
                    list.append(plugin)
                }
            } catch {
                errors[dir.lastPathComponent] = "\(error)"
            }
        }
        plugins = list
        loadErrors = errors
        CubiLog.write("plugins: \(list.map { "\($0.id)\(isEnabled($0.id) ? "" : "(off)")" }.joined(separator: ", "))")
    }

    func plugin(for agent: String) -> (any AgentPlugin)? {
        plugins.first { $0.id == agent }
    }

    func isEnabled(_ id: String) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
        return map[id] ?? (id == ClaudeCodePlugin.agentID)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var map = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
        map[id] = on
        UserDefaults.standard.set(map, forKey: Self.enabledKey)
        CubiLog.write("plugin \(id) \(on ? "enabled" : "disabled")")
        // Observers key off `plugins`; nudge them.
        plugins = plugins
    }

    // MARK: Secrets

    func secret(_ plugin: String, _ key: String) -> String? { Keychain.get(plugin: plugin, key: key) }

    func setSecret(_ plugin: String, _ key: String, _ value: String) {
        if value.isEmpty { Keychain.remove(plugin: plugin, key: key) } else { Keychain.set(plugin: plugin, key: key, value: value) }
    }
}
