// cubi — AppKit top-level entry. No SwiftUI App/Scene: the only windows are the notch panel and
// the settings panel, both created by hand.

import AppKit
import CubiKit

let arguments = CommandLine.arguments
// The mode is argv[1] and nothing else (see CubiCommand): a flag later on is never a mode.
let mode = CubiCommand.mode(arguments)
/// 1 when `flag` is the mode, for the blocks below that read the words after it.
func at(_ flag: String) -> Int? { mode == flag ? 1 : nil }
signal(SIGPIPE, SIG_IGN)

if mode == "--version" {
    // The bundle's Info.plist carries the released version (set from the git tag by scripts/bundle.sh);
    // `swift run` has no bundle and falls back to the constant.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? CubiInfo.version
    print("cubi \(version)")
    exit(0)
}

// Check a plugin folder the way the app loads it, plus what only the disk can tell (the panel file,
// each command's executable). Reads that folder only: no app, no log, no plugins directory.
//   --validate-plugin <folder>   exit 0 when it would load (warnings or not), 1 when not, 2 for usage
if let i = at("--validate-plugin") {
    guard i + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: cubi --validate-plugin <plugin folder>\n".utf8))
        exit(2)
    }
    let folder = URL(fileURLWithPath: (arguments[i + 1] as NSString).expandingTildeInPath).standardizedFileURL
    let report = PluginManifest.validate(directory: folder, home: CubiPaths.home.path)
    for e in report.errors { print("錯誤：\(e)") }
    for w in report.warnings { print("警告：\(w)") }
    print(report.errors.isEmpty ? "可以載入（\(report.summary ?? folder.lastPathComponent)）" : "不能載入（\(folder.path)）")
    exit(report.errors.isEmpty ? 0 : 1)
}

if let i = at("--render-icon"), i + 1 < arguments.count {
    let ok = IconRenderer.render(to: arguments[i + 1])
    exit(ok ? 0 : 1)
}

// Ask the running Ghostty which tab a session's name and directory match, without switching to it
// (the very script a robot click runs, `focus target` left out). Prints ok:title, ok:cwd or none:…:
//   --probe-ghostty <name, or "" for none> <cwd>
if let i = at("--probe-ghostty"), i + 2 < arguments.count {
    let script = MainActor.assumeIsolated { TerminalFocus.ghosttyScript(name: arguments[i + 1], cwd: arguments[i + 2], focus: false) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
}

// Offline preview of the island for layout work:
//   --render-island <hidden|compact|expanded|detail|approval|question|question-long|usage|usage-compact|focus-miss|focus-miss-named|focus-miss-untitled|focus-miss-detail|diff|focus|focus-12|focus-expanded|focus-nousage|floating|…-gear (any of them with 12 專注獎勵)|floating-approval|service-notice[-test|-long][-floating] (CUBI_RENDER_TITLE)|service-overlay-<knock|zap|shake> (CUBI_RENDER_FROM, CUBI_RENDER_MESSAGE, CUBI_RENDER_COLOR)> <botState> <out.png>
if let i = at("--render-island"), i + 3 < arguments.count {
    let ok = IconRenderer.renderIsland(mode: arguments[i + 1], botState: arguments[i + 2], to: arguments[i + 3])
    exit(ok ? 0 : 1)
}

// Offline picture of a tool plugin's panel, real web view and bridge, window kept off screen:
//   --render-panel <tool id> <out.png> [--dark] [--height N] [--eval JS] [--with-service]   (JS runs after load, the shot 2 s later; point the plugin at test data with its own env, e.g. CUBI_SPRINT_DIR)
// Both renders are dry runs for the plugins they run: CUBI_RENDER tells a plugin not to write its
// real data (a test-data override is fine). See docs/advanced.md.
if mode == "--render-panel" || mode == "--render-widget" { setenv("CUBI_RENDER", "1", 1) }

if let i = at("--render-panel"), i + 2 < arguments.count {
    let id = arguments[i + 1], out = URL(fileURLWithPath: arguments[i + 2]), dark = arguments.contains("--dark")
    let height = arguments.firstIndex(of: "--height").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
    let script = arguments.firstIndex(of: "--eval").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let registry = PluginRegistry()
        guard var tool = registry.tools.first(where: { $0.id == id }) else {
            FileHandle.standardError.write(Data("cubi: no tool plugin「\(id)」\n".utf8))
            exit(1)
        }
        // The panel runs its real commands: a plugin switched off in the settings is not run.
        guard registry.isEnabled(id) else {
            FileHandle.standardError.write(Data("cubi: tool plugin「\(id)」is disabled in the settings\n".utf8))
            exit(1)
        }
        if let height { tool.panel.height = height }
        // Its service only when asked for by name: it is really run, with whatever it does beyond
        // Cubi (its own defaults, keychain, network), told only by CUBI_RENDER that this is a dry run.
        // Nothing is put on screen for it; notices and presents are printed, presents answered unavailable.
        var services: PluginServices?
        if arguments.contains("--with-service") {
            let started = PluginServices(registry: registry,
                                         notice: { lines, _ in print("service notice: \(lines.joined(separator: " / "))") },
                                         present: { request, _ in print("service present: \(request.effect) from \(request.from)"); return "unavailable" })
            started.sync(only: id)
            services = started
        }
        PanelRenderer.render(tool, dark: dark, to: out, script: script, services: services) { ok in
            services?.stopAll()
            exit(ok ? 0 : 1)
        }
    }
    NSApplication.shared.run()
}

// Offline picture of a tool plugin's rows in a session's detail card, for a made-up session:
//   --render-widget <tool id> <session name> <out.png>   (point the plugin at test data, as above)
if let i = at("--render-widget"), i + 3 < arguments.count {
    let id = arguments[i + 1], name = arguments[i + 2], out = URL(fileURLWithPath: arguments[i + 3])
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let registry = PluginRegistry()
        guard let tool = registry.tools.first(where: { $0.id == id }), registry.isEnabled(id) else {
            FileHandle.standardError.write(Data("cubi: no enabled tool plugin「\(id)」\n".utf8))
            exit(1)
        }
        Task { @MainActor in exit(await WidgetRows.render(tool, name: name, to: out) ? 0 : 1) }
    }
    NSApplication.shared.run()
}

// Offline picture of one settings section, this machine's settings, window off screen:
//   --render-settings <claude|display|sleep|focus|calendar|plugins|scope> <out.png> [--dark]   (focus: made-up days, nothing saved)
if let i = at("--render-settings"), i + 2 < arguments.count {
    guard let page = SettingsView.Page(rawValue: arguments[i + 1]) else {
        FileHandle.standardError.write(Data("cubi: pages are \(SettingsView.Page.allCases.map(\.rawValue).joined(separator: "|"))\n".utf8))
        exit(2)
    }
    let ok = MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        return SettingsWindow.render(page: page, dark: arguments.contains("--dark"), to: URL(fileURLWithPath: arguments[i + 2]))
    }
    exit(ok ? 0 : 1)
}

// Hook management from the terminal (the same code the settings window uses).
//   --hooks-status             what is installed
//   --hooks-plan [--retire-notify]   show the diff an install would make, write nothing
//   --install-hooks [--retire-notify] install (backup + write), after showing the diff
//   --uninstall-hooks          remove Cubi's entries and restore the previous statusLine
if let m = mode, ["--hooks-status", "--hooks-plan", "--install-hooks", "--uninstall-hooks"].contains(m) {
    let i = 1
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
if mode == "--new-session" {
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
    if let refusal = DirectoryGuard.refusal(directory) {
        FileHandle.standardError.write(Data("cubi: \(refusal.message)\n".utf8))
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

// Run one of a tool plugin's commands the way its panel would (checks and all), for testing:
//   --tool-run <plugin id> <action> [args…]   prints {ok, out, err}; exit 1 when rejected or failed
//                                             an argument given as `-` is read from stdin (for text args)
//                                             every word after the action is an argument, a flag too
if mode == "--tool-run" {
    guard let run = CubiCommand.toolRun(arguments) else {
        FileHandle.standardError.write(Data("usage: cubi --tool-run <plugin id> <action> [args…|-]\n".utf8))
        exit(2)
    }
    let id = run.id, action = run.action
    let args = run.args.map { $0 == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : $0 }
    let code: Int32 = MainActor.assumeIsolated {
        let registry = PluginRegistry()
        guard let tool = registry.tools.first(where: { $0.id == id }) else {
            // Folder names are ids, so a refused manifest's reason is under the same name.
            let why = registry.loadErrors[id].map { "; refused: \($0)" } ?? ""
            FileHandle.standardError.write(Data("cubi: no tool plugin「\(id)」\(why) (loaded: \(registry.tools.map(\.id).joined(separator: ", ")))\n".utf8))
            return 1
        }
        guard registry.isEnabled(id) else {
            FileHandle.standardError.write(Data("cubi: tool plugin「\(id)」is disabled in the settings\n".utf8))
            return 1
        }
        do {
            let r = ToolRunner.run(try tool.invocation(action: action, args: args))
            let json = try JSONSerialization.data(withJSONObject: ["ok": r.code == 0, "out": r.out, "err": r.err], options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: json, as: UTF8.self))
            return r.code == 0 ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("cubi: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
