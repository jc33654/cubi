import Testing
@testable import CubiKit

@Test func everyRecordedFixtureDecodes() throws {
    let all = try Fixtures.all()
    #expect(all.count >= 30)
    for (name, env) in all {
        #expect(env.v == 1, "\(name)")
        #expect(env.agent == "claude-code", "\(name)")
        #expect(ClaudeCodeDecoder.decode(env) != nil, "\(name) did not decode")
    }
}

@Test func permissionRequestCarriesSuggestions() throws {
    let d = try Fixtures.decoded("PermissionRequest-1")
    guard case .permissionRequest(let tool, let input, let suggestions) = d.event else { Issue.record("wrong event"); return }
    #expect(tool == "Bash")
    #expect(input["command"]?.string == "curl -s https://example.com | head -3")
    #expect(suggestions.array?.first?["destination"]?.string == "localSettings")
    #expect(d.event.isBlocking)
    #expect(d.session.client.termProgram == "ghostty")
    #expect(d.session.client.tty?.hasPrefix("/dev/ttys") == true)
}

@Test func askUserQuestionIsAQuestion() throws {
    let d = try Fixtures.decoded("PreToolUse-AskUserQuestion-1")
    guard case .question(let q) = d.event else { Issue.record("wrong event"); return }
    let first = q["questions"]?.array?.first
    #expect(first?["options"]?.array?.count == 3)
    #expect(first?["multiSelect"]?.bool == false)
}

@Test func notificationTypes() throws {
    let a = try Fixtures.decoded("Notification-1")
    let b = try Fixtures.decoded("Notification-2")
    let types = [a.event, b.event].compactMap { e -> String? in
        if case .notification(let t, _) = e { return t }
        return nil
    }
    #expect(Set(types) == ["idle_prompt", "permission_prompt"])
}

@Test func sessionEndReasonAndSubagentType() throws {
    guard case .sessionEnd(let reason) = try Fixtures.decoded("SessionEnd-2").event else { Issue.record("x"); return }
    #expect(reason == "prompt_input_exit")
    guard case .subagentStart(let type) = try Fixtures.decoded("SubagentStart-1").event else { Issue.record("x"); return }
    #expect(type == "Explore")
}

@Test func toolLabels() {
    #expect(ClaudeCodeDecoder.toolLabel(tool: "Bash", input: .object(["command": .string("ls -la\necho hi")])) == "ls -la")
    #expect(ClaudeCodeDecoder.toolLabel(tool: "Edit", input: .object(["file_path": .string("/a/b/c.swift")])) == "Edit c.swift")
    #expect(ClaudeCodeDecoder.toolLabel(tool: "Bash", input: .object(["command": .string(String(repeating: "x", count: 80))])).count == 48)
    #expect(ClaudeCodeDecoder.toolLabel(tool: "WebFetch", input: .null) == "WebFetch")
}

@Test func unknownEventIsNilNotCrash() {
    let env = HookEnvelope(agent: "claude-code", event: "SomethingNew", payload: .object(["session_id": .string("s")]))
    #expect(ClaudeCodeDecoder.decode(env) == nil)
    let noSession = HookEnvelope(agent: "claude-code", event: "Stop", payload: .object([:]))
    #expect(ClaudeCodeDecoder.decode(noSession) == nil)
}

@Test func statuslineDecodesSessionStats() {
    let p: JSONValue = .object([
        "session_id": .string("s"), "hook_event_name": .string("Status"),
        "model": .object(["id": .string("claude-opus"), "display_name": .string("Opus")]),
        "workspace": .object(["project_dir": .string("/Users/me/p"), "current_dir": .string("/Users/me/p/src")]),
        "version": .string("2.1.312"), "effort": .string("high"),
        "cost": .object(["total_cost_usd": .number(0.5), "total_duration_ms": .number(12000), "total_api_duration_ms": .number(3000),
                         "total_lines_added": .number(10), "total_lines_removed": .number(2)]),
        "context_window": .object(["used_percentage": .number(40)]),
    ])
    let info = ClaudeCodeDecoder.statusline(p)
    #expect(info.model == "claude-opus" && info.session.modelDisplayName == "Opus")
    #expect(info.session.projectDir == "/Users/me/p" && info.session.currentDir == "/Users/me/p/src")
    #expect(info.session.version == "2.1.312" && info.session.effort == "high")
    #expect(info.session.totalDurationMS == 12000 && info.session.apiDurationMS == 3000)
    #expect(info.session.linesAdded == 10 && info.session.linesRemoved == 2 && info.costUSD == 0.5)
    #expect(ClaudeCodeDecoder.statusline(.object(["session_id": .string("s")])).session == SessionStats())
}
