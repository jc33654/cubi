import Foundation

/// The shell line that starts a Claude Code session in a directory, typed into a terminal the
/// app opens (Ghostty's initial input or Terminal.app's `do script`). Everything user-supplied is
/// single-quoted so the shell passes it through untouched, and the prompt comes after `--` so a
/// first message that starts with `-` is not taken for an option.
public enum SessionLaunch {
    public enum Resume: Hashable, Sendable {
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
        /// The settings file Cubi writes for the session (`ClaudeHookInstaller.restrictedSettings`):
        /// it switches the auto and bypass permission modes off, carries the user's deny rules,
        /// and, where they are installed, Cubi's hooks. Always there: without it the session
        /// could be put back into a mode that runs commands unasked.
        public var settingsFile: String
        /// Directories besides the working one the file tools may read.
        public var readDirs: [String]
        /// The permission rules for what the session may run unasked (`allowRule`): made by the
        /// app from action names, never handed in by a plugin. Everything else is refused.
        public var allowedTools: [String]

        public init(settingsFile: String, readDirs: [String], allowedTools: [String] = []) {
            self.settingsFile = settingsFile
            self.readDirs = readDirs
            self.allowedTools = allowedTools
        }
    }

    /// The only tools a restricted session gets. Fixed here: a plugin asks for the mode, never for flags.
    public static let restrictedTools = "Read,Grep,Glob,Bash"

    /// The rule that lets a restricted session run one action of one plugin through this cubi,
    /// and nothing else: only a single command that begins `<cubi> --tool-run <tool> <action>`
    /// followed by its arguments (the action name is matched whole: `review.updateX` is not
    /// `review.update`; a `cd … &&` in front, a `&&`, `;` or `|` behind, or a here-document all
    /// make the whole line refused — tried against Claude Code 2.1.322).
    /// The rule is matched against the command line as the session writes it, so the path is
    /// spelled exactly as plugins are told it (`CUBI_BIN`), and it must not need quoting: nil for
    /// a path, plugin id or action with anything but letters, digits, `/`, `.`, `_`, `-` in it
    /// (then the session is not opened at all, rather than opened with a rule that may not hold).
    public static func allowRule(cubi: String, tool: String, action: String) -> String? {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-")
        let isPlain = { (s: String) in !s.isEmpty && s.unicodeScalars.allSatisfy(plain.contains) }
        guard cubi.hasPrefix("/"), isPlain(cubi), isPlain(tool), isPlain(action), !tool.contains("/"), !action.contains("/") else { return nil }
        return "Bash(\(cubi) --tool-run \(tool) \(action):*)"
    }

    public static func command(directory: String, prompt: String?, resume: Resume, restricted: Restricted? = nil) -> String {
        var parts = ["cd", ClaudeHookInstaller.shellQuote(directory), "&&", "claude"]
        if let restricted {
            // `--tools` and `--add-dir` take any number of values: each is followed by another
            // option or the closing `--`, never by the prompt.
            // `--permission-mode dontAsk`: whatever would need asking is refused, and nothing is ever
            // asked. Restricted mode drops the settings files but not the permission mode; "auto"
            // (what an interactive session starts in) lets a classifier pass commands unasked, and
            // "manual" offers, on every prompt, to switch to "accept edits" for the rest of the
            // session — neither can be taken out by a setting. With no prompt there is nothing to
            // switch on; the settings file still shuts the auto and bypass modes (shift+tab).
            // `--disable-slash-commands`: the user's skills and commands are instructions too.
            parts += ["--restricted", "--permission-mode", "dontAsk", "--strict-mcp-config", "--disable-slash-commands",
                      "--tools", ClaudeHookInstaller.shellQuote(restrictedTools), "--settings", ClaudeHookInstaller.shellQuote(restricted.settingsFile)]
            for dir in restricted.readDirs { parts += ["--add-dir", ClaudeHookInstaller.shellQuote(dir)] }
            if !restricted.allowedTools.isEmpty { parts += ["--allowedTools"] + restricted.allowedTools.map(ClaudeHookInstaller.shellQuote) }
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

    /// The longest line that is typed into a terminal as it is. The app types into a tab whose
    /// shell is still starting, so the tty is in its cooked mode, and there macOS keeps at most
    /// 1024 bytes of an unfinished line (MAX_CANON): anything longer never ends — the newline is
    /// dropped with the rest, and the tab just sits there with the command on it.
    public static let maxTypedBytes = 900

    /// What to type for `command`: the command itself when it is short enough, else a line that
    /// reads it from `scriptPath` — and then `script` is what that file must hold. `source` runs
    /// it in the user's own shell, exactly as if it had been typed there: their PATH, their
    /// aliases, and the `cd` stays.
    public static func typed(_ command: String, scriptPath: String) -> (line: String, script: String?) {
        guard command.utf8.count + 1 > maxTypedBytes else { return (command, nil) }
        return ("source " + ClaudeHookInstaller.shellQuote(scriptPath), command + "\n")
    }

    public enum ScriptError: Error, Equatable { case notWritten(String) }

    /// Writes the file of a command too long to type into `directory`, for the user's eyes only
    /// (it holds the first prompt in full): the directory is made 0700 every time, whatever it
    /// was — that, not the file's own mode, is what keeps others out — and the file is created
    /// 0600. Files of earlier launches older than `keep` seconds are cleared out first: a shell
    /// reads its file within a second or two of it being written.
    public static func writeScript(_ script: String, to url: URL, keep: TimeInterval = 3600, now: Date = Date()) throws {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for old in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let written = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if old.pathExtension == "sh", written < now.addingTimeInterval(-keep) { try? fm.removeItem(at: old) }
        }
        guard fm.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ScriptError.notWritten(url.path)
        }
    }
}
