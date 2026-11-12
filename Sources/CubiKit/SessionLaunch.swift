/// The shell line that starts a Claude Code session in a directory, typed into a terminal the
/// app opens (Ghostty's initial input or Terminal.app's `do script`). Everything user-supplied is
/// single-quoted so the shell passes it through untouched, and the prompt comes after `--` so a
/// first message that starts with `-` is not taken for an option.
public enum SessionLaunch {
    public enum Resume: Equatable, Sendable {
        case none
        /// `--continue`: the most recent conversation in that directory, whichever it is.
        case last
        /// `--resume <id>`: this one.
        case session(String)
    }

    /// A session that takes nothing from the user's own settings: no allow rules (every command
    /// is asked about), no MCP servers, file tools confined to the directory and `readDirs`.
    /// For sessions whose first prompt points at text other people wrote.
    public struct Restricted: Equatable, Sendable {
        /// A settings file holding only Cubi's hooks, so the session still shows on the island
        /// (restricted mode ignores the user's settings, hooks included). nil: hooks not installed.
        public var settingsFile: String?
        /// Directories besides the working one the file tools may read.
        public var readDirs: [String]

        public init(settingsFile: String?, readDirs: [String]) {
            self.settingsFile = settingsFile
            self.readDirs = readDirs
        }
    }

    /// The only tools a restricted session gets. Fixed here: a plugin asks for the mode, never for flags.
    public static let restrictedTools = "Read,Grep,Glob,Bash"

    public static func command(directory: String, prompt: String?, resume: Resume, restricted: Restricted? = nil) -> String {
        var parts = ["cd", ClaudeHookInstaller.shellQuote(directory), "&&", "claude"]
        if let restricted {
            // `--tools` and `--add-dir` take any number of values: each is followed by another
            // option or the closing `--`, never by the prompt.
            parts += ["--restricted", "--strict-mcp-config", "--tools", ClaudeHookInstaller.shellQuote(restrictedTools)]
            if let file = restricted.settingsFile { parts += ["--settings", ClaudeHookInstaller.shellQuote(file)] }
            for dir in restricted.readDirs { parts += ["--add-dir", ClaudeHookInstaller.shellQuote(dir)] }
        }
        switch resume {
        case .none: break
        case .last: parts.append("--continue")
        case .session(let id): parts += ["--resume", ClaudeHookInstaller.shellQuote(id)]
        }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts += ["--", ClaudeHookInstaller.shellQuote(prompt)]
        } else if restricted != nil {
            parts.append("--")
        }
        return parts.joined(separator: " ")
    }
}
