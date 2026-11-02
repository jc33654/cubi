import AppKit
import CubiKit

/// Which terminal a new session opens in.
enum TerminalKind: String, CaseIterable, Identifiable {
    case ghostty, terminal
    var id: String { rawValue }
    var displayName: String { self == .ghostty ? "Ghostty" : "Terminal.app" }

    /// The terminal a session runs in, from the identity its hooks reported (same test as TerminalFocus).
    @MainActor static func forSession(_ info: SessionInfo) -> TerminalKind? {
        let program = (info.client.termProgram ?? "").lowercased()
        let bundle = info.client.bundleID ?? ""
        if program == "apple_terminal" || bundle == TerminalFocus.terminalBundle { return .terminal }
        if program == "ghostty" || bundle == TerminalFocus.ghosttyBundle { return .ghostty }
        return nil
    }

    /// Ghostty when it is installed, otherwise Terminal.app.
    @MainActor static var automatic: TerminalKind {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalFocus.ghosttyBundle) != nil ? .ghostty : .terminal
    }
}

struct LaunchRequest {
    var directory: String
    var prompt: String?
    var continueLast: Bool
    var terminal: TerminalKind
}

/// Opens a terminal tab in the project directory and types the `claude` command into it, as if
/// the user had: their shell, their PATH, and the shell stays when claude exits.
@MainActor
enum SessionLauncher {
    static func launch(_ request: LaunchRequest) {
        let command = SessionLaunch.command(directory: request.directory, prompt: request.prompt, continueLast: request.continueLast)
        CubiLog.write("launch \(request.terminal.rawValue): \(command)")
        let script = switch request.terminal {
        case .ghostty: ghosttyScript(directory: request.directory, command: command)
        case .terminal: terminalScript(command: command)
        }
        Task { await TerminalFocus.run(script, label: "launch \(request.terminal.rawValue)", fallbackBundle: nil) }
    }

    /// A new tab in the front window (a new window when there is none), started in the directory
    /// with the command as its first input.
    static func ghosttyScript(directory: String, command: String) -> String {
        """
        tell application "Ghostty"
          set cfg to new surface configuration
          set initial working directory of cfg to \(TerminalFocus.quote(directory))
          set initial input of cfg to (\(TerminalFocus.quote(command)) & linefeed)
          if (count of windows) > 0 then
            new tab in front window with configuration cfg
          else
            new window with configuration cfg
          end if
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
