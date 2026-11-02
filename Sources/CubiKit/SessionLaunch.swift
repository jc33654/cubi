/// The shell line that starts a Claude Code session in a directory, typed into a terminal the
/// app opens (Ghostty's initial input or Terminal.app's `do script`). Everything user-supplied is
/// single-quoted so the shell passes it through untouched.
public enum SessionLaunch {
    public static func command(directory: String, prompt: String?, continueLast: Bool) -> String {
        var parts = ["cd", ClaudeHookInstaller.shellQuote(directory), "&&", "claude"]
        if continueLast { parts.append("--continue") }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(ClaudeHookInstaller.shellQuote(prompt))
        }
        return parts.joined(separator: " ")
    }
}
