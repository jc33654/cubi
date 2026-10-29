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

    public struct Options: Sendable, Equatable {
        public var chainStatusline = true
        /// Hook commands containing any of these substrings are dropped (the user's old tooling).
        public var retireCommandsContaining: [String] = []
        public init(chainStatusline: Bool = true, retireCommandsContaining: [String] = []) {
            self.chainStatusline = chainStatusline
            self.retireCommandsContaining = retireCommandsContaining
        }
    }

    // MARK: - Inspection

    public static func status(_ settings: JSONValue) -> Status {
        let hooks = settings["hooks"]?.object ?? [:]
        let installed = (hooks["SessionStart"]?.array ?? []).contains(where: groupIsOurs)
        let chained = settings["statusLine"]?["command"]?.string?.contains(marker) ?? false
        var legacy: [String] = []
        for group in hooks["Notification"]?.array ?? [] {
            for hook in group["hooks"]?.array ?? [] {
                if let c = hook["command"]?.string, c.contains("notify-hook") { legacy.append(c) }
            }
        }
        return Status(hooksInstalled: installed, statuslineChained: chained, legacyNotificationCommands: legacy)
    }

    public static func groupIsOurs(_ group: JSONValue) -> Bool {
        (group["hooks"]?.array ?? []).contains { $0["command"]?.string?.contains(marker) ?? false }
    }

    // MARK: - Plans

    public static func installPlan(settings: JSONValue, options: Options = Options()) -> Plan {
        var root = settings.object ?? [:]
        var hooks = root["hooks"]?.object ?? [:]

        for (event, timeout) in events {
            var groups = (hooks[event]?.array ?? []).filter { !groupIsOurs($0) }
            if !options.retireCommandsContaining.isEmpty {
                groups = groups.filter { group in
                    !(group["hooks"]?.array ?? []).contains { hook in
                        let c = hook["command"]?.string ?? ""
                        return options.retireCommandsContaining.contains { c.contains($0) }
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
        if options.chainStatusline {
            let current = root["statusLine"]
            let currentCommand = current?["command"]?.string ?? ""
            if !currentCommand.contains(marker) {
                previous = current
                var sl = current?.object ?? ["type": .string("command")]
                sl["type"] = .string("command")
                sl["command"] = .string(currentCommand.isEmpty
                    ? "\(relayCommand) --agent claude-code statusline"
                    : "\(relayCommand) --agent claude-code statusline --then \(currentCommand)")
                root["statusLine"] = .object(sl)
            }
        }

        let after = JSONValue.object(root)
        return Plan(before: settings, after: after, diff: diff(settings, after), changed: after != settings, previousStatusLine: previous)
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
                sl["command"] = .string(String(then[r.upperBound...]))
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
