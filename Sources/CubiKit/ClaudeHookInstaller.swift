import Foundation

/// Computes what installing or removing Cubi's Claude Code hooks does to a settings object.
/// Pure: the app reads the file, asks for a plan, shows the diff, then writes `plan.after`.
public enum ClaudeHookInstaller {
    /// Every command Cubi writes contains this, so its own entries can be found and replaced.
    public static let marker = "cubi-hook"
    /// Portable across machines: Claude Code runs hook commands through a shell.
    public static let relayCommand = "$HOME/.cubi/bin/cubi-hook"

    public static let events: [(name: String, timeout: Int)] = [
        ("SessionStart", 10), ("SessionEnd", 1), ("UserPromptSubmit", 10),
        ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
        ("PermissionRequest", 120), ("Notification", 10),
        ("Stop", 10), ("StopFailure", 10), ("SubagentStart", 10), ("SubagentStop", 10),
    ]

    public struct Status: Sendable, Equatable {
        public var hooksInstalled: Bool
        public var statuslineChained: Bool
        /// Commands of other people's hooks that Cubi could retire (e.g. the old notify-hook.sh).
        public var legacyNotificationCommands: [String]
    }

    public struct Plan: Sendable, Equatable {
        public var before: JSONValue
        public var after: JSONValue
        public var diff: String
        public var changed: Bool
        /// The statusLine object that was in place before chaining; the app stores it for uninstall.
        public var previousStatusLine: JSONValue?
    }

    // MARK: - Inspection

    public static func status(_ settings: JSONValue) -> Status {
        let hooks = settings["hooks"]?.object ?? [:]
        let installed = (hooks["SessionStart"]?.array ?? []).contains { groupIsOurs($0) }
        let chained = settings["statusLine"]?["command"]?.string?.contains(marker) ?? false
        var legacy: [String] = []
        for group in hooks["Notification"]?.array ?? [] {
            for hook in group["hooks"]?.array ?? [] {
                if let c = hook["command"]?.string, c.contains("notify-hook") { legacy.append(c) }
            }
        }
        return Status(hooksInstalled: installed, statuslineChained: chained, legacyNotificationCommands: legacy)
    }

    /// Hook groups Cubi installed for `agent`: every relay command names its agent, so one
    /// plugin's uninstall leaves the others' hooks alone.
    public static func groupIsOurs(_ group: JSONValue, agent: String = "claude-code") -> Bool {
        (group["hooks"]?.array ?? []).contains { $0["command"]?.string?.contains(agentTag(agent)) ?? false }
    }

    /// "cubi-hook --agent <id> ", trailing space included: agent ids may contain hyphens, so
    /// "foo" must not match "foo-bar".
    public static func agentTag(_ agent: String) -> String { "\(marker) --agent \(agent) " }

    /// The previous statusLine command travels as one argument of the chained command, so its
    /// own quotes, pipes and `$` reach the relay untouched and are interpreted once, by the relay's shell.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellUnquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") else { return s }
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    // MARK: - Plans

    /// `retireCommandsContaining`: hook commands containing any of these substrings are dropped
    /// (the user's old tooling that Cubi replaces).
    public static func installPlan(settings: JSONValue, retireCommandsContaining: [String] = []) -> Plan {
        var root = settings.object ?? [:]
        var hooks = root["hooks"]?.object ?? [:]

        for (event, timeout) in events {
            var groups = (hooks[event]?.array ?? []).filter { !groupIsOurs($0) }
            if !retireCommandsContaining.isEmpty {
                groups = groups.filter { group in
                    !(group["hooks"]?.array ?? []).contains { hook in
                        let c = hook["command"]?.string ?? ""
                        return retireCommandsContaining.contains { c.contains($0) }
                    }
                }
            }
            groups.append(hookGroup(command: "\(relayCommand) --agent claude-code --event \(event)", timeout: timeout))
            if event == "PreToolUse" {
                groups.append(hookGroup(command: "\(relayCommand) --agent claude-code --event PreToolUse --tool AskUserQuestion",
                                        timeout: 120, matcher: "AskUserQuestion"))
            }
            hooks[event] = .array(groups)
        }
        root["hooks"] = .object(hooks)

        var previous: JSONValue? = nil
        let current = root["statusLine"]
        let currentCommand = current?["command"]?.string ?? ""
        if !currentCommand.contains(marker) {
            previous = current
            var sl = current?.object ?? ["type": .string("command")]
            sl["type"] = .string("command")
            sl["command"] = .string(currentCommand.isEmpty
                ? "\(relayCommand) --agent claude-code statusline"
                : "\(relayCommand) --agent claude-code statusline --then \(shellQuote(currentCommand))")
            root["statusLine"] = .object(sl)
        }

        let after = JSONValue.object(root)
        return Plan(before: settings, after: after, diff: diff(settings, after), changed: after != settings, previousStatusLine: previous)
    }

    /// Settings holding nothing but Cubi's hooks, for a restricted session's `--settings`: that
    /// mode ignores the user's settings file, and with it the hooks that put the session on the island.
    /// Each command carries `--restricted`, which the relay passes on, so the app knows the
    /// session's approvals must not offer "always allow".
    ///
    /// One of the settings files Claude Code would have read for the session, with where a rule
    /// path that starts with a single slash is counted from in that file.
    public struct DenyLayer {
        public var settings: JSONValue
        public var anchor: String

        /// ~/.claude/settings.json: `/x` there means `~/.claude/x`.
        public static func user(_ settings: JSONValue) -> DenyLayer { .init(settings: settings, anchor: "~/.claude") }
        /// A project's `.claude/settings.json` or `.claude/settings.local.json`: `/x` there means
        /// `<the session's working directory>/x`, written from the file system's root as `//…`.
        public static func project(_ settings: JSONValue, workingDirectory: String) -> DenyLayer {
            .init(settings: settings, anchor: "/" + workingDirectory)
        }
    }

    /// The tools whose rules are paths (as opposed to commands or domains).
    public static let pathTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "Glob", "Grep"]

    /// A deny rule as it must be written in another settings file to mean the same thing. In a
    /// path rule a single leading slash is counted from the file the rule sits in (`//` is the
    /// file system's root), so copied as it is into ~/.cubi it would point under ~/.cubi and deny
    /// nothing. `//…`, `~/…`, `**/…`, `./…` and bare paths mean the same anywhere, and rules of
    /// other tools (`Bash(/usr/bin/x:*)`) are not paths: all of those are left as they are.
    public static func portableDenyRule(_ rule: String, anchor: String) -> String {
        guard rule.hasSuffix(")"), let open = rule.firstIndex(of: "(") else { return rule }
        let tool = String(rule[..<open]), spec = rule[rule.index(after: open)...].dropLast()
        guard pathTools.contains(tool), spec.hasPrefix("/"), !spec.hasPrefix("//") else { return rule }
        return "\(tool)(\(anchor)\(spec))"
    }

    /// The `permissions.deny` of each layer comes along, in that order, each rule once and
    /// rewritten where it would otherwise change meaning; nothing else of those files does — no
    /// allow rules, no ask rules, no status line. Restricted mode drops them whole, and a session
    /// meant to be safer must not get to read what the user forbade.
    ///
    /// Always there, whatever the layers hold: the auto and bypass permission modes are switched
    /// off, so the session cannot be moved (shift+tab, or a prompt's "and switch to auto") into a
    /// mode that runs commands without asking. `hooks` false (Cubi's hooks are not installed):
    /// no hooks, the rest the same.
    public static func restrictedSettings(denyingAs layers: [DenyLayer], hooks: Bool = true) -> JSONValue {
        var root = hooks ? hooksOnlySettings().object ?? [:] : [:]
        var permissions: [String: JSONValue] = ["disableAutoMode": .string("disable"), "disableBypassPermissionsMode": .string("disable")]
        var deny: [JSONValue] = []
        for layer in layers {
            for rule in layer.settings["permissions"]?["deny"]?.array ?? [] {
                let carried = rule.string.map { JSONValue.string(portableDenyRule($0, anchor: layer.anchor)) } ?? rule
                if !deny.contains(carried) { deny.append(carried) }
            }
        }
        if !deny.isEmpty { permissions["deny"] = .array(deny) }
        root["permissions"] = .object(permissions)
        return .object(root)
    }

    /// Where Claude Code reads `.claude/settings.local.json` from for a session started in
    /// `directory`: the root of the git repository that holds it (the nearest folder upwards with
    /// a `.git`), else the directory itself. The home directory and the file system's root are
    /// never taken for a repository root.
    public static func localSettingsDirectory(for directory: String, home: String, exists: (String) -> Bool) -> String {
        var dir = directory
        while dir != "/" && dir != home && !dir.isEmpty {
            if exists(dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return directory
    }

    public static func hooksOnlySettings() -> JSONValue {
        let plain = "--agent claude-code --event ", marked = "--agent claude-code --restricted --event "
        func mark(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let s): return .string(s.replacingOccurrences(of: plain, with: marked))
            case .array(let a): return .array(a.map(mark))
            case .object(let o): return .object(o.mapValues(mark))
            default: return value
            }
        }
        return .object(["hooks": mark(installPlan(settings: .object([:])).after["hooks"] ?? .object([:]))])
    }

    public static func uninstallPlan(settings: JSONValue, previousStatusLine: JSONValue?) -> Plan {
        var root = settings.object ?? [:]
        if var hooks = root["hooks"]?.object {
            for (event, _) in events {
                let kept = (hooks[event]?.array ?? []).filter { !groupIsOurs($0) }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = .array(kept) }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = .object(hooks) }
        }
        if root["statusLine"]?["command"]?.string?.contains(marker) ?? false {
            if let previous = previousStatusLine, !previous.isNull {
                root["statusLine"] = previous
            } else if let then = root["statusLine"]?["command"]?.string, let r = then.range(of: " --then ") {
                // No record of the original: recover it from the chained command itself.
                var sl = root["statusLine"]?.object ?? [:]
                sl["command"] = .string(shellUnquote(String(then[r.upperBound...])))
                root["statusLine"] = .object(sl)
            } else {
                root.removeValue(forKey: "statusLine")
            }
        }
        let after = JSONValue.object(root)
        return Plan(before: settings, after: after, diff: diff(settings, after), changed: after != settings, previousStatusLine: nil)
    }

    static func hookGroup(command: String, timeout: Int, matcher: String? = nil) -> JSONValue {
        var group: [String: JSONValue] = [
            "hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(Double(timeout))])]),
        ]
        if let matcher { group["matcher"] = .string(matcher) }
        return .object(group)
    }

    // MARK: - Diff for the preview

    /// Unified-style diff of the two serialized files, with two lines of context.
    public static func diff(_ a: JSONValue, _ b: JSONValue) -> String {
        let la = String(decoding: SettingsFile.serialize(a), as: UTF8.self).components(separatedBy: "\n")
        let lb = String(decoding: SettingsFile.serialize(b), as: UTF8.self).components(separatedBy: "\n")
        let lines = EditSummaryBuilder.lineDiff(la, lb)
        var keep = [Bool](repeating: false, count: lines.count)
        for (i, l) in lines.enumerated() where l.kind != .context {
            for j in max(0, i - 2)...min(lines.count - 1, i + 2) { keep[j] = true }
        }
        var out: [String] = []
        var lastKept = -1
        for (i, l) in lines.enumerated() where keep[i] {
            if lastKept >= 0 && i != lastKept + 1 { out.append("…") }
            let prefix = l.kind == .added ? "+" : (l.kind == .removed ? "-" : " ")
            out.append(prefix + l.text)
            lastKept = i
        }
        return out.joined(separator: "\n")
    }
}
