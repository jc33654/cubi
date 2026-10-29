import Foundation
import Observation
import CubiKit

/// State behind the settings window's Claude Code section.
@MainActor
@Observable
final class HookSetupModel {
    var status: ClaudeHookInstaller.Status?
    var error: String?
    var message: String?
    var retireLegacyNotification = false
    /// A preview waiting for the user's confirmation.
    var pending: HookSetup.Preview?
    var pendingIsUninstall = false
    var projectLocalFiles: [URL] = []
    /// After a write: hooks are read when a session starts.
    var needsRestart = false

    static let projectLocalKey = "projectLocalHookDirs"

    func refresh() {
        do {
            status = try HookSetup.status()
            error = nil
        } catch {
            status = nil
            self.error = error.localizedDescription
        }
        let dirs = (UserDefaults.standard.stringArray(forKey: Self.projectLocalKey) ?? [])
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        projectLocalFiles = HookSetup.projectLocalHookFiles(in: dirs)
    }

    func previewInstall(plugin: any AgentPlugin = ClaudeCodePlugin()) {
        do {
            let retire = plugin.id == ClaudeCodePlugin.agentID && retireLegacyNotification ? ["notify-hook.sh"] : []
            guard let p = try HookSetup.installPreview(plugin: plugin, options: .init(retireCommandsContaining: retire)) else {
                message = "\(plugin.displayName) 要手動安裝。"; return
            }
            if !p.plan.changed { message = "已經裝好了，沒有要改的東西。"; return }
            pending = p
            pendingIsUninstall = false
        } catch { self.error = error.localizedDescription }
    }

    func previewUninstall(plugin: any AgentPlugin = ClaudeCodePlugin()) {
        do {
            guard let p = try HookSetup.uninstallPreview(plugin: plugin) else { message = "\(plugin.displayName) 要手動移除。"; return }
            if !p.plan.changed { message = "\(p.url.lastPathComponent) 裡沒有 Cubi 的東西。"; return }
            pending = p
            pendingIsUninstall = true
        } catch { self.error = error.localizedDescription }
    }

    func confirmPending() {
        guard let p = pending else { return }
        do {
            let backup = try HookSetup.apply(p)
            message = (pendingIsUninstall ? "已移除。" : "已安裝。") + (backup.map { "備份：\($0.lastPathComponent)" } ?? "")
            needsRestart = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        pending = nil
        refresh()
    }

    func cancelPending() { pending = nil }

    func stripProjectLocal(_ url: URL) {
        do {
            try HookSetup.stripProjectLocalHooks(at: url)
            message = "已從 \(url.path) 移除測試用 hooks（備份在同目錄 backups/）。"
        } catch { self.error = error.localizedDescription }
        refresh()
    }
}
