import Foundation
import CubiKit

/// The app's side of installing Claude Code hooks: real paths, the saved previous statusLine,
/// and the project-local capture file left over from development.
enum HookSetup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var backupDir: URL { home.appendingPathComponent(".claude/backups/cubi") }
    static var agentRecordURL: URL { home.appendingPathComponent(".cubi/agents/claude-code.json") }

    struct Preview {
        let plan: ClaudeHookInstaller.Plan
        let snapshot: SettingsFile.Snapshot
    }

    static func status() throws -> ClaudeHookInstaller.Status {
        ClaudeHookInstaller.status(try SettingsFile.read(at: settingsURL).object)
    }

    static func installPreview(options: ClaudeHookInstaller.Options) throws -> Preview {
        let snapshot = try SettingsFile.read(at: settingsURL)
        return Preview(plan: ClaudeHookInstaller.installPlan(settings: snapshot.object, options: options), snapshot: snapshot)
    }

    static func uninstallPreview() throws -> Preview {
        let snapshot = try SettingsFile.read(at: settingsURL)
        return Preview(plan: ClaudeHookInstaller.uninstallPlan(settings: snapshot.object, previousStatusLine: savedPreviousStatusLine()), snapshot: snapshot)
    }

    /// Writes the previewed result. Fails if the file changed since the preview.
    @discardableResult
    static func apply(_ preview: Preview) throws -> URL? {
        let backup = try SettingsFile.write(SettingsFile.serialize(preview.plan.after), to: settingsURL,
                                            expecting: preview.snapshot.bytes, backupDir: backupDir)
        if let previous = preview.plan.previousStatusLine {
            savePreviousStatusLine(previous)
        } else if !ClaudeHookInstaller.status(preview.plan.after).statuslineChained {
            try? FileManager.default.removeItem(at: agentRecordURL)
        }
        CubiLog.write("settings.json written (backup: \(backup?.lastPathComponent ?? "none"))")
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
            let ours = hooks.values.contains { ($0.array ?? []).contains(where: ClaudeHookInstaller.groupIsOurs) }
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
