// cubi — AppKit top-level entry. No SwiftUI App/Scene: the only windows are the notch panel and
// the settings panel, both created by hand.

import AppKit
import CubiKit

let arguments = CommandLine.arguments
signal(SIGPIPE, SIG_IGN)

if arguments.contains("--version") {
    // The bundle's Info.plist carries the released version (set from the git tag by scripts/bundle.sh);
    // `swift run` has no bundle and falls back to the constant.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? CubiInfo.version
    print("cubi \(version)")
    exit(0)
}

if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
    let ok = IconRenderer.render(to: arguments[i + 1])
    exit(ok ? 0 : 1)
}

// Offline preview of the island for layout work:
//   --render-island <hidden|compact|expanded|detail|approval|question|usage|usage-compact|diff|floating|floating-approval> <botState> <out.png>
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

// Start a Claude Code session from the terminal the way the island does (also how it is tested):
//   --new-session <dir> [--continue | --resume <id>] [--prompt <text>] [--terminal ghostty|terminal]
if arguments.contains("--new-session") {
    func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    func usage() -> Never {
        FileHandle.standardError.write(Data("usage: cubi --new-session <dir> [--continue | --resume <id>] [--prompt <text>] [--terminal ghostty|terminal]\n".utf8))
        exit(2)
    }
    guard let rawDirectory = value(after: "--new-session") else { usage() }
    for flag in ["--prompt", "--resume", "--terminal"] where arguments.contains(flag) && value(after: flag) == nil { usage() }
    let terminal: TerminalKind? = value(after: "--terminal").map { name in
        guard let kind = TerminalKind(rawValue: name) else { usage() }
        return kind
    }
    // Relative to where the command was typed; the new terminal starts in $HOME and needs the full path.
    let directory = URL(fileURLWithPath: (rawDirectory as NSString).expandingTildeInPath).standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
        FileHandle.standardError.write(Data("cubi: not a directory: \(directory)\n".utf8))
        exit(2)
    }
    let resume: SessionLaunch.Resume = value(after: "--resume").map { .session($0) } ?? (arguments.contains("--continue") ? .last : .none)
    let request = LaunchRequest(directory: directory, prompt: value(after: "--prompt"), resume: resume,
                                terminal: terminal ?? MainActor.assumeIsolated { TerminalKind.automatic })
    var outcome: String?? = nil
    Task { @MainActor in outcome = .some(await SessionLauncher.launch(request)) }
    while outcome == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    if let failure = outcome! {
        FileHandle.standardError.write(Data("cubi: \(failure)\n".utf8))
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
