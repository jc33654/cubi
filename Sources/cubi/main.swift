// cubi — AppKit top-level entry. No SwiftUI App/Scene: the only windows are the notch panel and
// the settings panel, both created by hand.

import AppKit
import CubiKit

let arguments = CommandLine.arguments
signal(SIGPIPE, SIG_IGN)

if arguments.contains("--version") {
    print("cubi \(CubiInfo.version)")
    exit(0)
}

if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
    let ok = IconRenderer.render(to: arguments[i + 1])
    exit(ok ? 0 : 1)
}

// Offline preview of the island for layout work: --render-island <hidden|compact|expanded> <botState> <out.png>
if let i = arguments.firstIndex(of: "--render-island"), i + 3 < arguments.count {
    let ok = IconRenderer.renderIsland(mode: arguments[i + 1], botState: arguments[i + 2], to: arguments[i + 3])
    exit(ok ? 0 : 1)
}

// Hook management from the terminal (the same code the settings window uses).
//   --hooks-status             what is installed
//   --hooks-plan [--retire-notify]   show the diff an install would make, write nothing
//   --install-hooks [--retire-notify] install (backup + write), after showing the diff
//   --uninstall-hooks          remove Cubi's entries and restore the previous statusLine
if let i = arguments.firstIndex(where: { ["--hooks-status", "--hooks-plan", "--install-hooks", "--uninstall-hooks"].contains($0) }) {
    let retire = arguments.contains("--retire-notify")
    let retireCommands = retire ? ["notify-hook.sh"] : []
    do {
        switch arguments[i] {
        case "--hooks-status":
            let s = try HookSetup.status()
            print("hooks: \(s.hooksInstalled ? "installed" : "not installed")")
            print("statusLine: \(s.statuslineChained ? "chained" : "not chained")")
            if !s.legacyNotificationCommands.isEmpty { print("legacy Notification hooks: \(s.legacyNotificationCommands.joined(separator: ", "))") }
            exit(0)
        case "--hooks-plan":
            guard let p = try HookSetup.installPreview(retireCommandsContaining: retireCommands) else { exit(1) }
            print(p.plan.changed ? p.plan.diff : "already installed, nothing to change")
            exit(0)
        case "--install-hooks":
            guard let p = try HookSetup.installPreview(retireCommandsContaining: retireCommands) else { exit(1) }
            guard p.plan.changed else { print("already installed, nothing to change"); exit(0) }
            print(p.plan.diff)
            guard RelayInstaller.ensureInstalled() != nil else {
                FileHandle.standardError.write(Data("cubi: could not install the relay the hooks point at (run this from Cubi.app/Contents/MacOS/cubi)\n".utf8))
                exit(1)
            }
            let backup = try HookSetup.apply(p)
            print("written \(HookSetup.settingsURL.path)" + (backup.map { " (backup: \($0.path))" } ?? ""))
            print("Restart your Claude Code sessions: hooks are read when a session starts.")
            exit(0)
        default:
            guard let p = try HookSetup.uninstallPreview() else { exit(1) }
            guard p.plan.changed else { print("nothing of Cubi's in settings.json"); exit(0) }
            print(p.plan.diff)
            let backup = try HookSetup.apply(p)
            print("written \(HookSetup.settingsURL.path)" + (backup.map { " (backup: \($0.path))" } ?? ""))
            exit(0)
        }
    } catch {
        FileHandle.standardError.write(Data("cubi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
