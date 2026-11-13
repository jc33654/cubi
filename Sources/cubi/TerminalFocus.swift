import AppKit
import CubiKit

/// Brings the terminal tab a session runs in to the front. Strategy by terminal:
///   Terminal.app  → the tab whose tty matches (same trick as focus-terminal-tab.sh)
///   Ghostty       → the terminal whose title ends with the session name (Claude Code's own
///                   registry has the freshest one), else the one terminal whose cwd matches:
///                   several tabs in the same project are ambiguous, and a wrong jump is worse
///                   than none
///   Claude.app    → the app's `claude://code/continue?session=` link, with the app's own id for
///                   the session (its claude-code-sessions records), else just the app
///   anything else → activate the app by bundle id (tab-level focus is not scriptable)
///   no identity   → the hooks ran without TERM_PROGRAM/tty: try Ghostty then Terminal.app by
///                   name and cwd, and only switch to what actually matched
/// osascript runs off the main thread with a timeout; the first call triggers the Automation prompt.
@MainActor
enum TerminalFocus {
    static let ghosttyBundle = "com.mitchellh.ghostty"
    static let terminalBundle = "com.apple.Terminal"
    static let desktopBundle = "com.anthropic.claudefordesktop"

    /// The scriptable terminal a session runs in, from the identity its hooks reported.
    static func kind(for info: SessionInfo) -> TerminalKind? {
        let program = (info.client.termProgram ?? "").lowercased()
        let bundle = info.client.bundleID ?? ""
        if program == "apple_terminal" || bundle == terminalBundle { return .terminal }
        if program == "ghostty" || bundle == ghosttyBundle { return .ghostty }
        return nil
    }

    /// What a miss says: two short lines for the island's wing, the whole of it on the session's
    /// ticker. A session with no name of its own can be told apart by one (/rename); a named one
    /// was found in several tabs, or in none whose title still ends with it.
    struct Miss: Equatable {
        let wing: [String]
        let ticker: String

        static let unnamed = Miss(wing: ["找不到它的視窗", "請 /rename 取名"],
                                  ticker: "沒跳過去：同資料夾有好幾個 Claude 分不出來，到那個視窗打 /rename 取名字就點得到")
        static let named = Miss(wing: ["找不到它的視窗", "同名的分頁太多"],
                                ticker: "沒跳過去：有好幾個分頁符合這個名字，請關掉不用的或換個名字")
    }

    /// `onMiss` runs (on the main actor) when Ghostty answered but no single tab was the session's
    /// own, so nothing jumped: the island says so instead of staying silent. (Terminal.app goes by
    /// tty: a miss there is a closed tab, which neither wording fits.)
    static func focus(_ info: SessionInfo, onMiss: (@MainActor (Miss) -> Void)? = nil) {
        let client = info.client
        let bundle = client.bundleID ?? ""
        // A /rename reaches Claude Code's registry (and the tab title) before the next status line.
        // Only a name the user chose counts: a derived one (`proj-32`) is not what the tab shows.
        // Only the title-matching branches need it; Terminal.app goes by tty.
        var name: String {
            let fromRegistry = ClaudeSessionRegistry.entry(for: info.id, in: ClaudeSessionRegistry.directory(home: CubiPaths.home.path))?.userName ?? ""
            return !fromRegistry.isEmpty ? fromRegistry : (info.explicitName ? info.name : "")
        }
        let cwd = info.cwd ?? ""

        switch kind(for: info) {
        case .terminal:
            guard let tty = client.tty else { return activate(bundle: terminalBundle) }
            Task { await run(terminalScript(tty: tty), label: "Terminal \(tty) \(info.id.prefix(8))", fallbackBundle: terminalBundle) }
        case .ghostty:
            let named = name
            Task { missed(await run(ghosttyScript(name: named, cwd: cwd), label: "Ghostty \(info.name) \(info.id.prefix(8)) \(named.isEmpty ? "unnamed" : "named")", fallbackBundle: ghosttyBundle),
                          named.isEmpty ? .unnamed : .named, onMiss) }
        case nil where bundle == desktopBundle:
            focusDesktop(info)
        case nil where !bundle.isEmpty:
            activate(bundle: bundle)
        case nil:
            CubiLog.write("focus: no terminal identity for session \(info.id.prefix(8)); guessing by name/cwd")
            Task { await guess(name: name, cwd: cwd, label: info.name) }
        }
    }

    /// The script ran and said "none": no window of its own was found (an error is not a miss).
    private static func missed(_ result: (ok: Bool, error: String), _ miss: Miss, _ onMiss: (@MainActor (Miss) -> Void)?) {
        if !result.ok, result.error.hasPrefix("none"), let onMiss { onMiss(miss) }
    }

    /// Without an identity, ask each scriptable terminal that is running; stop at the first match.
    private static func guess(name: String, cwd: String, label: String) async {
        if isRunning(ghosttyBundle),
           await run(ghosttyScript(name: name, cwd: cwd), label: "Ghostty? \(label)", fallbackBundle: nil).ok { return }
        if isRunning(terminalBundle), !name.isEmpty,
           await run(terminalByTitleScript(name: name), label: "Terminal? \(label)", fallbackBundle: nil).ok { return }
        CubiLog.write("focus: nothing matched for \(label)")
    }

    /// A session inside the Claude app: its deep link, handed to the app itself (not whichever app
    /// owns `claude://`), switches it to that conversation. Without a live record for it (a
    /// just-started session, an archived conversation, or an app version that files things
    /// elsewhere) the app only comes to the front. The records are big, so the lookup runs off
    /// the main thread like the scripts do.
    private static func focusDesktop(_ info: SessionInfo) {
        Task {
            let id = info.id, short = id.prefix(8)
            let directory = ClaudeDesktopSessions.directory(home: CubiPaths.home.path)
            let entries = await Task.detached(priority: .userInitiated) { ClaudeDesktopSessions.entries(in: directory) }.value
            guard let entry = ClaudeDesktopSessions.entry(for: id, in: entries), let link = ClaudeDesktopSessions.continueLink(entry.localID) else {
                CubiLog.write("focus Claude.app \(short): no live app record for the session (\(entries.count) read); activating the app")
                return activate(bundle: desktopBundle)
            }
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundle) else {
                return CubiLog.write("focus Claude.app \(short): app \(desktopBundle) not found")
            }
            CubiLog.write("focus Claude.app \(short): \(entry.localID)")
            NSWorkspace.shared.open([link], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                CubiLog.write("focus Claude.app \(short): link refused (\(error.localizedDescription)); activating the app")
                Task { @MainActor in activate(bundle: desktopBundle) }
            }
        }
    }

    private static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    private static func activate(bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            CubiLog.write("focus: app \(bundle) not found")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Runs the script; ok when what it printed starts with "ok", else `error` says what it printed instead (its
    /// stderr when there is one). Not ok also activates `fallbackBundle` when given.
    @discardableResult
    static func run(_ source: String, label: String, fallbackBundle: String?) async -> (ok: Bool, error: String) {
        let result = await Task.detached(priority: .userInitiated) { () -> (String, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return ("", "osascript failed to start: \(error)") }
            // Watchdog: an unresponsive app must not hang the script forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
            process.waitUntilExit()
            let text = { (p: Pipe) in String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            return (text(out), text(err))
        }.value
        CubiLog.write("focus \(label): \(result.0.isEmpty ? "(no output)" : result.0)\(result.1.isEmpty ? "" : " err=\(result.1)")")
        let ok = result.0.hasPrefix("ok")
        if !ok, let fallbackBundle { activate(bundle: fallbackBundle) }
        let error = result.1.isEmpty ? result.0 : result.1
        return (ok, ok || !error.isEmpty ? error : "osascript 沒有回應（5 秒逾時）")
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t) is \(quote(tty)) then
                set selected of t to true
                set index of w to 1
                return "ok"
              end if
            end repeat
          end repeat
          return "none"
        end tell
        """
    }

    /// Terminal.app without a tty to go by: the tab whose title carries the session name. Titles are
    /// "<status glyph> <name>", so match the whole name after a space: "小工具" must not match "小工具審查員".
    static func terminalByTitleScript(name: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if (name of w) contains (" " & \(quote(name)) & " ") or (custom title of t) ends with (" " & \(quote(name))) then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
          return "none"
        end tell
        """
    }

    /// Every step only accepts exactly one terminal: the title (two tabs can carry the same name,
    /// e.g. a resumed session next to the original; then the cwd narrows them), else the cwd. With
    /// several sessions in one project directory "the first match" is usually the wrong tab, and
    /// no jump beats a wrong one; a lone "Claude Code" title is not a match either (that is just
    /// whichever tab was last cleared). Prints "ok:title" or "ok:cwd", else "none:" with how many
    /// terminals each step found (t: title, n: title and cwd, c: cwd), for the log.
    static func ghosttyScript(name: String, cwd: String) -> String {
        """
        tell application "Ghostty"
          set target to missing value
          set via to ""
          set titled to -1
          set narrowedCount to -1
          set inCwd to -1
          if \(quote(name)) is not "" then
            set hits to {}
            repeat with t in terminals
              if (name of t) ends with (" " & \(quote(name))) then set end of hits to t
            end repeat
            set titled to count of hits
            if (count of hits) > 1 and \(quote(cwd)) is not "" then
              set narrowed to {}
              repeat with t in hits
                if (working directory of t) is \(quote(cwd)) then set end of narrowed to t
              end repeat
              set hits to narrowed
              set narrowedCount to count of hits
            end if
            if (count of hits) is 1 then
              set target to item 1 of hits
              set via to "title"
            end if
          end if
          if target is missing value and \(quote(cwd)) is not "" then
            set hits to {}
            repeat with t in terminals
              if (working directory of t) is \(quote(cwd)) then set end of hits to t
            end repeat
            set inCwd to count of hits
            if (count of hits) is 1 then
              set target to item 1 of hits
              set via to "cwd"
            end if
          end if
          if target is missing value then return "none:t=" & titled & ",n=" & narrowedCount & ",c=" & inCwd
          focus target
          return "ok:" & via
        end tell
        """
    }
}
