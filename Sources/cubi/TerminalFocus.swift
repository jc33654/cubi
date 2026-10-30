import AppKit
import CubiKit

/// Brings the terminal tab a session runs in to the front. Strategy by terminal:
///   Terminal.app  → the tab whose tty matches (same trick as focus-terminal-tab.sh)
///   Ghostty       → the terminal whose title contains the session name, else whose cwd matches
///   anything else → activate the app by bundle id (tab-level focus is not scriptable)
///   no identity   → the hooks ran without TERM_PROGRAM/tty: try Ghostty then Terminal.app by
///                   name and cwd, and only switch to what actually matched
/// osascript runs off the main thread with a timeout; the first call triggers the Automation prompt.
@MainActor
enum TerminalFocus {
    static let ghosttyBundle = "com.mitchellh.ghostty"
    static let terminalBundle = "com.apple.Terminal"

    static func focus(_ info: SessionInfo) {
        let client = info.client
        let program = (client.termProgram ?? "").lowercased()
        let bundle = client.bundleID ?? ""
        let name = info.explicitName ? info.name : ""
        let cwd = info.cwd ?? ""

        if program == "apple_terminal" || bundle == terminalBundle {
            guard let tty = client.tty else { return activate(bundle: terminalBundle) }
            Task { await run(terminalScript(tty: tty), label: "Terminal \(tty)", fallbackBundle: terminalBundle) }
        } else if program == "ghostty" || bundle == ghosttyBundle {
            Task { await run(ghosttyScript(name: name, cwd: cwd, anyClaude: true), label: "Ghostty \(info.name)", fallbackBundle: ghosttyBundle) }
        } else if !bundle.isEmpty {
            activate(bundle: bundle)
        } else {
            CubiLog.write("focus: no terminal identity for session \(info.id.prefix(8)); guessing by name/cwd")
            Task { await guess(name: name, cwd: cwd, label: info.name) }
        }
    }

    /// Without an identity, ask each scriptable terminal that is running; stop at the first match.
    private static func guess(name: String, cwd: String, label: String) async {
        if isRunning(ghosttyBundle),
           await run(ghosttyScript(name: name, cwd: cwd, anyClaude: false), label: "Ghostty? \(label)", fallbackBundle: nil) { return }
        if isRunning(terminalBundle), !name.isEmpty,
           await run(terminalByTitleScript(name: name), label: "Terminal? \(label)", fallbackBundle: nil) { return }
        CubiLog.write("focus: nothing matched for \(label)")
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

    /// Runs the script; true when it printed "ok". Otherwise activates `fallbackBundle` when given.
    @discardableResult
    private static func run(_ source: String, label: String, fallbackBundle: String?) async -> Bool {
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
        let ok = result.0 == "ok"
        if !ok, let fallbackBundle { activate(bundle: fallbackBundle) }
        return ok
    }

    private static func quote(_ s: String) -> String {
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

    /// Terminal.app without a tty to go by: the tab whose title carries the session name.
    static func terminalByTitleScript(name: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if (name of w) contains \(quote(name)) or (custom title of t) contains \(quote(name)) then
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

    /// `anyClaude`: with nothing better, take any tab titled "Claude Code" (only when we know the
    /// session lives in Ghostty).
    static func ghosttyScript(name: String, cwd: String, anyClaude: Bool) -> String {
        """
        tell application "Ghostty"
          set target to missing value
          if \(quote(name)) is not "" then
            repeat with t in terminals
              if (name of t) contains \(quote(name)) then
                set target to t
                exit repeat
              end if
            end repeat
          end if
          if target is missing value and \(quote(cwd)) is not "" then
            repeat with t in terminals
              if (working directory of t) is \(quote(cwd)) then
                set target to t
                exit repeat
              end if
            end repeat
          end if
          if target is missing value and \(anyClaude) then
            repeat with t in terminals
              if (name of t) contains "Claude Code" then
                set target to t
                exit repeat
              end if
            end repeat
          end if
          if target is missing value then return "none"
          focus target
          return "ok"
        end tell
        """
    }
}
