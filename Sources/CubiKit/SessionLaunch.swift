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

    public static func command(directory: String, prompt: String?, resume: Resume) -> String {
        var parts = ["cd", ClaudeHookInstaller.shellQuote(directory), "&&", "claude"]
        switch resume {
        case .none: break
        case .last: parts.append("--continue")
        case .session(let id): parts += ["--resume", ClaudeHookInstaller.shellQuote(id)]
        }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts += ["--", ClaudeHookInstaller.shellQuote(prompt)]
        }
        return parts.joined(separator: " ")
    }
}
