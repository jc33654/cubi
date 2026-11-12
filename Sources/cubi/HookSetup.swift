import Foundation
import CubiKit

/// The app's side of installing an agent's hooks: real paths, the saved previous statusLine,
/// and the project-local capture file left over from development.
enum HookSetup {
    static let home = CubiPaths.home
    static var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var backupDir: URL { home.appendingPathComponent(".claude/backups/cubi") }
    static var agentRecordURL: URL { home.appendingPathComponent(".cubi/agents/claude-code.json") }
    /// Only Cubi's hooks, for restricted sessions (`claude --restricted --settings <this>`).
    static var restrictedSettingsURL: URL { home.appendingPathComponent(".cubi/restricted-settings.json") }

    struct Preview {
        let plan: ClaudeHookInstaller.Plan
        let snapshot: SettingsFile.Snapshot
        let url: URL
        let pluginID: String
    }

    /// The settings file a plugin installs into, or nil when it is installed by hand.
    static func settingsURL(for plugin: any AgentPlugin) -> URL? {
        guard case .jsonHooks(let file) = plugin.installMode else { return nil }
        // Not expandingTildeInPath: that ignores $HOME, and the CLI must follow it (see CubiPaths).
        if file == "~" || file.hasPrefix("~/") { return home.appendingPathComponent(String(file.dropFirst(2))) }
        return URL(fileURLWithPath: file)
    }

    static func status(plugin: any AgentPlugin = ClaudeCodePlugin()) throws -> ClaudeHookInstaller.Status {
        guard let url = settingsURL(for: plugin) else { return plugin.installStatus(settings: .object([:])) }
        return plugin.installStatus(settings: try SettingsFile.read(at: url).object)
    }

    static func installPreview(plugin: any AgentPlugin = ClaudeCodePlugin(), retireCommandsContaining: [String] = []) throws -> Preview? {
        guard let url = settingsURL(for: plugin) else { return nil }
        let snapshot = try SettingsFile.read(at: url)
        guard let plan = plugin.installPlan(settings: snapshot.object, retireCommandsContaining: retireCommandsContaining) else { return nil }
        return Preview(plan: plan, snapshot: snapshot, url: url, pluginID: plugin.id)
    }

    static func uninstallPreview(plugin: any AgentPlugin = ClaudeCodePlugin()) throws -> Preview? {
        guard let url = settingsURL(for: plugin) else { return nil }
        let snapshot = try SettingsFile.read(at: url)
        let previous = plugin.id == ClaudeCodePlugin.agentID ? savedPreviousStatusLine() : nil
        guard let plan = plugin.uninstallPlan(settings: snapshot.object, previousStatusLine: previous) else { return nil }
        return Preview(plan: plan, snapshot: snapshot, url: url, pluginID: plugin.id)
    }

    /// The settings file a restricted session is started with, written afresh each time so it
    /// always matches this build's hooks and the user's deny rules as they are now. nil when
    /// Cubi's hooks are not installed: the session then runs without this file, and its approvals
    /// come up in the terminal only. A settings.json that cannot be read is an error, never an
    /// empty set of deny rules.
    ///
    /// `directory` is where the session starts: its `.claude/settings.json` gives its deny rules
    /// too, and so does the `.claude/settings.local.json` Claude Code would read for it (the git
    /// repository root's, when the directory is inside a repository).
    static func writeRestrictedSettings(directory: String) throws -> URL? {
        let user = try SettingsFile.read(at: settingsURL).object
        guard ClaudeHookInstaller.status(user).hooksInstalled else { return nil }
        let shared = URL(fileURLWithPath: directory).appendingPathComponent(".claude/settings.json")
        let localRoot = ClaudeHookInstaller.localSettingsDirectory(for: directory, home: home.path) { FileManager.default.fileExists(atPath: $0) }
        let local = URL(fileURLWithPath: localRoot).appendingPathComponent(".claude/settings.local.json")
        let layers: [ClaudeHookInstaller.DenyLayer] = [
            .user(user),
            .project(try SettingsFile.read(at: shared).object, workingDirectory: directory),
            .project(try SettingsFile.read(at: local).object, workingDirectory: directory),
        ]
        let url = restrictedSettingsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SettingsFile.serialize(ClaudeHookInstaller.restrictedSettings(denyingAs: layers)).write(to: url, options: .atomic)
        return url
    }

    /// Writes the previewed result. Fails if the file changed since the preview.
    @discardableResult
    static func apply(_ preview: Preview) throws -> URL? {
        let backupDir = preview.url.deletingLastPathComponent().appendingPathComponent("backups/cubi")
        let backup = try SettingsFile.write(SettingsFile.serialize(preview.plan.after), to: preview.url,
                                            expecting: preview.snapshot.bytes, backupDir: backupDir)
        if preview.pluginID == ClaudeCodePlugin.agentID {
            if let previous = preview.plan.previousStatusLine {
                savePreviousStatusLine(previous)
            } else if !ClaudeHookInstaller.status(preview.plan.after).statuslineChained {
                try? FileManager.default.removeItem(at: agentRecordURL)
            }
            if !ClaudeHookInstaller.status(preview.plan.after).hooksInstalled {
                try? FileManager.default.removeItem(at: restrictedSettingsURL)
            }
        }
        CubiLog.write("\(preview.url.lastPathComponent) written for \(preview.pluginID) (backup: \(backup?.lastPathComponent ?? "none"))")
        return backup
    }

    // MARK: - Record of what was there before chaining the status line

    static func savedPreviousStatusLine() -> JSONValue? {
        guard let data = try? Data(contentsOf: agentRecordURL),
              let record = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return record["previousStatusLine"]
    }

    private static func savePreviousStatusLine(_ value: JSONValue) {
        let record: JSONValue = .object(["previousStatusLine": value, "savedAt": .number(Date().timeIntervalSince1970)])
        try? FileManager.default.createDirectory(at: agentRecordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SettingsFile.serialize(record).write(to: agentRecordURL)
    }

    // MARK: - Development leftovers

    /// Project-local settings that also run cubi-hook: with global hooks installed they would
    /// fire every event twice. Returns the files found under the given project directories.
    static func projectLocalHookFiles(in directories: [URL]) -> [URL] {
        directories.compactMap { dir in
            let url = dir.appendingPathComponent(".claude/settings.local.json")
            guard let snapshot = try? SettingsFile.read(at: url), snapshot.bytes != nil else { return nil }
            let hooks = snapshot.object["hooks"]?.object ?? [:]
            let ours = hooks.values.contains { ($0.array ?? []).contains { ClaudeHookInstaller.groupIsOurs($0) } }
            return ours ? url : nil
        }
    }

    /// Removes cubi-hook groups from a project-local file, keeping anything else in it.
    static func stripProjectLocalHooks(at url: URL) throws {
        let snapshot = try SettingsFile.read(at: url)
        var root = snapshot.object.object ?? [:]
        if var hooks = root["hooks"]?.object {
            for (event, groups) in hooks {
                let kept = (groups.array ?? []).filter { !ClaudeHookInstaller.groupIsOurs($0) }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = .array(kept) }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = .object(hooks) }
        }
        try SettingsFile.write(SettingsFile.serialize(.object(root)), to: url, expecting: snapshot.bytes,
                               backupDir: url.deletingLastPathComponent().appendingPathComponent("backups"))
    }
}
