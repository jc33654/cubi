import Foundation

/// A plugin described by `plugins/<id>/manifest.json` instead of code. v1 covers what can be
/// declared safely: identity, capabilities, secrets, `json-hooks` installation, and an event map
/// with JSON-path field picks. Replies and adapters are not run from manifests yet, so a manifest
/// agent is monitor-only: its approvals fall through to the agent's own prompt.
public struct ManifestPlugin: AgentPlugin {
    public struct EventRule: Sendable, Equatable {
        public var canonical: String          // sessionStart, prompt, toolStart, toolEnd, permissionRequest, question, notification, stop, sessionEnd
        public var map: [String: String]      // canonical field → JSON path like "$.tool_name"
    }

    public var id: String
    public var displayName: String
    public var accentColor: RGB
    public var capabilities: AgentCapabilities
    public var secrets: [SecretSpec]
    public var installMode: InstallMode
    public var installEntries: [(event: String, command: String, timeout: Int)]
    public var events: [String: EventRule]

    public enum LoadError: Error, Equatable { case badID(String), missingField(String), badInstall }

    // MARK: - Loading

    public static func load(url: URL) throws -> ManifestPlugin {
        let data = try Data(contentsOf: url)
        return try parse(try JSONDecoder().decode(JSONValue.self, from: data))
    }

    public static func parse(_ m: JSONValue) throws -> ManifestPlugin {
        guard let id = m["id"]?.string else { throw LoadError.missingField("id") }
        guard AgentID.isValid(id) else { throw LoadError.badID(id) }
        guard let name = m["name"]?.string else { throw LoadError.missingField("name") }

        var caps = AgentCapabilities()
        for c in m["capabilities"]?.array ?? [] {
            switch c.string {
            case "approvals": caps.insert(.approvals)
            case "questions": caps.insert(.questions)
            case "statusline": caps.insert(.statusline)
            default: break
            }
        }
        let secrets = (m["secrets"]?.array ?? []).compactMap { s -> SecretSpec? in
            guard let key = s["key"]?.string else { return nil }
            return SecretSpec(key: key, label: s["label"]?.string ?? key, required: s["required"]?.bool ?? false)
        }

        let install = m["install"]
        let mode: InstallMode
        var entries: [(String, String, Int)] = []
        switch install?["mode"]?.string {
        case "json-hooks":
            guard let file = install?["file"]?.string else { throw LoadError.badInstall }
            mode = .jsonHooks(file: file)
            for e in install?["entries"]?.array ?? [] {
                guard let event = e["event"]?.string, let command = e["command"]?.string else { throw LoadError.badInstall }
                // Install status and uninstall find the plugin's hooks by this tag.
                guard command.contains(ClaudeHookInstaller.agentTag(id)) else { throw LoadError.badInstall }
                entries.append((event, command, Int(e["timeout"]?.double ?? 10)))
            }
        case "manual", nil:
            mode = .manual(instructions: install?["instructions"]?.string ?? "")
        default:
            throw LoadError.badInstall
        }

        var events: [String: EventRule] = [:]
        for (native, rule) in m["events"]?.object ?? [:] {
            guard let canonical = rule["canonical"]?.string else { continue }
            var map: [String: String] = [:]
            for (k, v) in rule["map"]?.object ?? [:] { if let s = v.string { map[k] = s } }
            events[native] = EventRule(canonical: canonical, map: map)
        }

        return ManifestPlugin(id: id, displayName: name, accentColor: RGB(hexString: m["color"]?.string) ?? RGB(hex: 0x8B8B8B),
                              capabilities: caps, secrets: secrets, installMode: mode, installEntries: entries, events: events)
    }

    // MARK: - AgentPlugin

    public func decode(_ envelope: HookEnvelope) -> DecodedHook? {
        let p = envelope.payload
        let native = envelope.event ?? p["hook_event_name"]?.string ?? ""
        guard let rule = events[native] else { return nil }
        func pick(_ field: String, _ fallback: String) -> JSONValue? {
            Self.path(rule.map[field] ?? fallback, in: p)
        }
        guard let sessionID = pick("session", "$.session_id")?.string else { return nil }
        let session = SessionRef(id: sessionID, cwd: pick("cwd", "$.cwd")?.string, client: envelope.client,
                                 transcriptPath: pick("transcript", "$.transcript_path")?.string)
        let tool = pick("tool", "$.tool_name")?.string ?? "?"
        let input = pick("input", "$.tool_input") ?? .null
        let event: CanonicalEvent?
        switch rule.canonical {
        case "sessionStart": event = .sessionStart(source: pick("source", "$.source")?.string)
        case "prompt": event = .prompt(pick("prompt", "$.prompt")?.string ?? "")
        case "toolStart": event = .toolStart(tool: tool, input: input)
        case "toolEnd": event = .toolEnd(tool: tool, ok: pick("ok", "$.ok")?.bool ?? true, input: input, response: pick("response", "$.tool_response") ?? .null)
        case "permissionRequest": event = .permissionRequest(tool: tool, input: input, suggestions: .null)
        case "question": event = .question(input)
        case "notification": event = .notification(type: pick("type", "$.notification_type")?.string ?? "", message: pick("message", "$.message")?.string ?? "")
        case "stop": event = .stop(lastMessage: pick("message", "$.last_assistant_message")?.string)
        case "sessionEnd": event = .sessionEnd(reason: pick("reason", "$.reason")?.string)
        default: event = nil
        }
        return event.map { DecodedHook(session: session, event: $0, toolUseID: pick("toolUseID", "$.tool_use_id")?.string) }
    }

    /// Manifest plugins cannot answer yet: the agent's own prompt takes over.
    public func reply(_ reply: CanonicalReply, for context: PendingContext) -> String? { nil }

    public func installPlan(settings: JSONValue, retireCommandsContaining: [String]) -> ClaudeHookInstaller.Plan? {
        guard case .jsonHooks = installMode, !installEntries.isEmpty else { return nil }
        var root = settings.object ?? [:]
        var hooks = root["hooks"]?.object ?? [:]
        for (event, command, timeout) in installEntries {
            var groups = (hooks[event]?.array ?? []).filter { !ClaudeHookInstaller.groupIsOurs($0, agent: id) }
            groups.append(.object(["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(Double(timeout))])])]))
            hooks[event] = .array(groups)
        }
        root["hooks"] = .object(hooks)
        let after = JSONValue.object(root)
        return ClaudeHookInstaller.Plan(before: settings, after: after, diff: ClaudeHookInstaller.diff(settings, after), changed: after != settings, previousStatusLine: nil)
    }

    public func uninstallPlan(settings: JSONValue, previousStatusLine: JSONValue?) -> ClaudeHookInstaller.Plan? {
        guard case .jsonHooks = installMode else { return nil }
        var root = settings.object ?? [:]
        if var hooks = root["hooks"]?.object {
            for (event, groups) in hooks {
                let kept = (groups.array ?? []).filter { !ClaudeHookInstaller.groupIsOurs($0, agent: id) }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = .array(kept) }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = .object(hooks) }
        }
        let after = JSONValue.object(root)
        return ClaudeHookInstaller.Plan(before: settings, after: after, diff: ClaudeHookInstaller.diff(settings, after), changed: after != settings, previousStatusLine: nil)
    }

    public func installStatus(settings: JSONValue) -> ClaudeHookInstaller.Status {
        let hooks = settings["hooks"]?.object ?? [:]
        let installed = hooks.values.contains { ($0.array ?? []).contains { ClaudeHookInstaller.groupIsOurs($0, agent: id) } }
        return ClaudeHookInstaller.Status(hooksInstalled: installed, statuslineChained: false, legacyNotificationCommands: [])
    }

    // MARK: - Tiny JSON path: "$.a.b"

    static func path(_ expr: String, in value: JSONValue) -> JSONValue? {
        guard expr.hasPrefix("$") else { return nil }
        var current = value
        for key in expr.dropFirst().split(separator: ".") {
            guard let next = current[String(key)] else { return nil }
            current = next
        }
        return current
    }
}

public extension RGB {
    init?(hexString: String?) {
        guard var s = hexString else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}
