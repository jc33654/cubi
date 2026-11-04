import Foundation
import Observation
import CubiKit

/// What each tool plugin's `session.info` last said about each session, for the detail card.
/// Refreshes are driven by the card being on screen (SessionWidgetView), never by a timer here.
@MainActor
@Observable
final class SessionWidgetStore {
    struct Entry: Equatable {
        var output: PluginIO.WidgetOutput?
        /// A failure of the command itself (not the plugin's own `error` field).
        var failure: String?
        var loading = false
    }

    private let registry: PluginRegistry
    private(set) var entries: [String: Entry] = [:]
    /// The session as the plugin should see it; set by the coordinator, which owns the store.
    @ObservationIgnored var input: (String) -> PluginIO.SessionInput? = { _ in nil }
    @ObservationIgnored private var generation: [String: Int] = [:]

    init(registry: PluginRegistry) { self.registry = registry }

    /// Enabled tools that declare a session hook, in manifest order.
    func tools() -> [ToolPlugin] {
        registry.tools.filter { $0.session != nil && registry.isEnabled($0.id) }
    }

    func entry(session: String, plugin: String) -> Entry? { entries[Self.key(session, plugin)] }

    func refresh(session: String, plugin: ToolPlugin) async {
        guard let hook = plugin.session else { return }
        await run(hook.info, session: session, plugin: plugin)
    }

    /// A button in the card: run that command, then ask `session.info` again. A failed action
    /// stays on screen (no refresh) until the next one.
    func act(_ action: String, session: String, plugin: ToolPlugin) async {
        guard plugin.isHook(action) else { return }
        CubiLog.write("widget \(plugin.id) \(action) session=\(session.prefix(8))")
        if await run(action, session: session, plugin: plugin) { await refresh(session: session, plugin: plugin) }
    }

    @discardableResult
    private func run(_ action: String, session: String, plugin: ToolPlugin) async -> Bool {
        let key = Self.key(session, plugin.id)
        guard registry.isEnabled(plugin.id), let input = input(session) else { return false }
        let gen = (generation[key] ?? 0) + 1
        generation[key] = gen
        var entry = entries[key] ?? Entry()
        entry.loading = true
        entries[key] = entry
        let out: String
        switch await ToolRunner.hook(plugin, action: action, json: input.json()) {
        case .success(let text): out = text
        case .failure(let f):
            CubiLog.write("widget \(plugin.id) \(action): \(f.message)")
            finish(key, gen: gen, failure: f.message)
            return false
        }
        do {
            finish(key, gen: gen, output: try PluginIO.WidgetOutput.parse(out, tool: plugin))
            return true
        } catch {
            CubiLog.write("widget \(plugin.id) \(action): \(error.localizedDescription)")
            finish(key, gen: gen, failure: error.localizedDescription)
            return false
        }
    }

    /// Only the newest request for a key may write; an older one that finishes late is dropped.
    private func finish(_ key: String, gen: Int, output: PluginIO.WidgetOutput? = nil, failure: String? = nil) {
        guard generation[key] == gen else { return }
        var entry = entries[key] ?? Entry()
        entry.loading = false
        if let output { entry.output = output; entry.failure = nil } else { entry.failure = failure }
        entries[key] = entry
    }

    private static func key(_ session: String, _ plugin: String) -> String { session + "|" + plugin }
}
