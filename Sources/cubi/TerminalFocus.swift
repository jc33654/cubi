import AppKit
import CubiKit

/// Brings the terminal tab a session runs in to the front. Strategy by terminal:
///   Terminal.app  → the tab whose tty matches (same trick as focus-terminal-tab.sh)
///   Ghostty       → the terminal whose title contains the session name, else whose cwd matches
///   anything else → activate the app by bundle id (tab-level focus is not scriptable)
/// osascript runs off the main thread with a timeout; the first call triggers the Automation prompt.
@MainActor
enum TerminalFocus {
    static func focus(_ info: SessionInfo) {
        let client = info.client
        let program = (client.termProgram ?? "").lowercased()
        let bundle = client.bundleID ?? ""

        if program == "apple_terminal" || bundle == "com.apple.Terminal" {
            guard let tty = client.tty else { return activate(bundle: "com.apple.Terminal") }
            runScript(terminalScript(tty: tty), fallbackBundle: "com.apple.Terminal", label: "Terminal \(tty)")
        } else if program == "ghostty" || bundle == "com.mitchellh.ghostty" {
            runScript(ghosttyScript(name: info.explicitName ? info.name : "", cwd: info.cwd ?? ""),
                      fallbackBundle: "com.mitchellh.ghostty", label: "Ghostty \(info.name)")
        } else if !bundle.isEmpty {
            activate(bundle: bundle)
        } else {
            CubiLog.write("focus: no terminal identity for session \(info.id.prefix(8))")
        }
    }

    private static func activate(bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            CubiLog.write("focus: app \(bundle) not found")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private static func runScript(_ source: String, fallbackBundle: String, label: String) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                await MainActor.run { CubiLog.write("focus: osascript failed to start: \(error)") }
                return
            }
            // Watchdog: an unresponsive app must not hang the script forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
            process.waitUntilExit()
            let result = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await MainActor.run {
                CubiLog.write("focus \(label): \(result.isEmpty ? "(no output)" : result)\(errText.isEmpty ? "" : " err=\(errText)")")
                if result != "ok" { activate(bundle: fallbackBundle) }
            }
        }
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

    static func ghosttyScript(name: String, cwd: String) -> String {
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
          -- Claude Code titles an unnamed session "✳ Claude Code"; better that tab than nothing.
          if target is missing value then
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
