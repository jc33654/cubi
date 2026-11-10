import AppKit
import CubiKit

/// Which terminal a new session opens in.
enum TerminalKind: String, CaseIterable {
    case ghostty, terminal
    var displayName: String { self == .ghostty ? "Ghostty" : "Terminal.app" }

    /// Ghostty when it is installed, otherwise Terminal.app.
    @MainActor static var automatic: TerminalKind {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalFocus.ghosttyBundle) != nil ? .ghostty : .terminal
    }
}

struct LaunchRequest {
    var directory: String
    var prompt: String?
    var resume: SessionLaunch.Resume
    var terminal: TerminalKind
}

/// Opens a terminal tab in the project directory and types the `claude` command into it, as if
/// the user had: their shell, their PATH, and the shell stays when claude exits.
@MainActor
enum SessionLauncher {
    /// nil when a terminal opened; otherwise what went wrong, for the caller to show.
    /// Ghostty refusing (not scriptable, Automation denied, hung) falls back to Terminal.app.
    static func launch(_ request: LaunchRequest) async -> String? {
        let command = SessionLaunch.command(directory: request.directory, prompt: request.prompt, resume: request.resume)
        let promptNote = request.prompt.map { " prompt=\($0.count) chars" } ?? ""
        CubiLog.write("launch \(request.terminal.rawValue) in \(request.directory) resume=\(request.resume)\(promptNote)")
        var result = await TerminalFocus.run(script(for: request.terminal, directory: request.directory, command: command),
                                             label: "launch \(request.terminal.rawValue)", fallbackBundle: nil)
        if !result.ok, request.terminal == .ghostty {
            CubiLog.write("launch: Ghostty failed (\(result.error)); trying Terminal.app")
            result = await TerminalFocus.run(terminalScript(command: command), label: "launch terminal", fallbackBundle: nil)
        }
        return result.ok ? nil : result.error
    }

    static func alert(_ error: String) {
        Notice.show("開不了終端", error + "\n\n第一次用會需要在「系統設定 → 隱私與安全性 → 自動化」允許 Cubi 控制終端。詳細在 ~/Library/Logs/cubi.log。")
    }

    private static func script(for terminal: TerminalKind, directory: String, command: String) -> String {
        switch terminal {
        case .ghostty: ghosttyScript(directory: directory, command: command)
        case .terminal: terminalScript(command: command)
        }
    }

    /// A new tab in the front window (a new window when there is none), started in the directory;
    /// the command is then typed in with `input text`. Not `initial input`: Ghostty 1.3.1 mangles
    /// non-ASCII there (UTF-8 bytes re-encoded as Latin-1, so 知識庫 arrives as ç¥èåº«), while
    /// `input text` passes it through intact.
    static func ghosttyScript(directory: String, command: String) -> String {
        """
        tell application "Ghostty"
          set cfg to new surface configuration
          set initial working directory of cfg to \(TerminalFocus.quote(directory))
          if (count of windows) > 0 then
            set t to new tab in front window with configuration cfg
            set target to focused terminal of t
          else
            set w to new window with configuration cfg
            set target to focused terminal of selected tab of w
          end if
          input text (\(TerminalFocus.quote(command)) & linefeed) to target
          activate
          return "ok"
        end tell
        """
    }

    /// Terminal.app: `do script` opens a new window running the line in a login shell.
    static func terminalScript(command: String) -> String {
        """
        tell application "Terminal"
          do script \(TerminalFocus.quote(command))
          activate
          return "ok"
        end tell
        """
    }
}
