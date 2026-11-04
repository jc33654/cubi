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
        var at: Date?
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
        await run(hook.info, session: session, plugin: plugin, log: false)
    }

    /// A button in the card: run that command, then ask `session.info` again.
    func act(_ action: String, session: String, plugin: ToolPlugin) async {
        guard plugin.isHook(action) else { return }
        await run(action, session: session, plugin: plugin, log: true)
        await refresh(session: session, plugin: plugin)
    }

    private func run(_ action: String, session: String, plugin: ToolPlugin, log: Bool) async {
        let key = Self.key(session, plugin.id)
        guard registry.isEnabled(plugin.id), let input = input(session) else { return }
        let gen = (generation[key] ?? 0) + 1
        generation[key] = gen
        var entry = entries[key] ?? Entry()
        entry.loading = true
        entries[key] = entry
        let invocation: ToolPlugin.Invocation
        do {
            invocation = try plugin.invocation(action: action, args: [input.json()])
        } catch {
            finish(key, gen: gen, failure: error.localizedDescription)
            return
        }
        if log { CubiLog.write("widget \(plugin.id) \(action) session=\(session.prefix(8))") }
        let r = await Task.detached(priority: .userInitiated) { ToolRunner.run(invocation) }.value
        if r.code != 0 {
            CubiLog.write("widget \(plugin.id) \(action): exit \(r.code) \(r.err.prefix(200))")
            finish(key, gen: gen, failure: r.err.isEmpty ? "exit \(r.code)" : String(r.err.prefix(200)))
            return
        }
        do {
            finish(key, gen: gen, output: try PluginIO.WidgetOutput.parse(r.out, tool: plugin))
        } catch {
            CubiLog.write("widget \(plugin.id) \(action): \(error.localizedDescription)")
            finish(key, gen: gen, failure: error.localizedDescription)
        }
    }

    /// Only the newest request for a key may write; an older one that finishes late is dropped.
    private func finish(_ key: String, gen: Int, output: PluginIO.WidgetOutput? = nil, failure: String? = nil) {
        guard generation[key] == gen else { return }
        var entry = entries[key] ?? Entry()
        entry.loading = false
        entry.at = Date()
        if let output { entry.output = output; entry.failure = nil } else { entry.failure = failure }
        entries[key] = entry
    }

    private static func key(_ session: String, _ plugin: String) -> String { session + "|" + plugin }
}
