import Foundation
import Testing
@testable import CubiKit

@Test func onlyTheMatcherHookIsAQuestion() {
    let payload: JSONValue = .object([
        "session_id": .string("s"), "hook_event_name": .string("PreToolUse"),
        "tool_name": .string("AskUserQuestion"),
        "tool_input": .object(["questions": .array([.object(["question": .string("q"), "options": .array([.object(["label": .string("a")])])])])]),
    ])
    let matcher = HookEnvelope(agent: "claude-code", event: "PreToolUse", tool: "AskUserQuestion", payload: payload)
    let plain = HookEnvelope(agent: "claude-code", event: "PreToolUse", tool: nil, payload: payload)
    guard case .question = ClaudeCodeDecoder.decode(matcher)?.event else { Issue.record("matcher should be a question"); return }
    guard case .toolStart(let tool, _) = ClaudeCodeDecoder.decode(plain)?.event else { Issue.record("plain should be toolStart"); return }
    #expect(tool == "AskUserQuestion")
}

@Test func plainAskUserQuestionToolStartDoesNotTouchPending() {
    var store = SessionStore()
    let ref = SessionRef(id: "s", cwd: nil, client: HookClient())
    _ = store.apply(DecodedHook(session: ref, event: .question(.object([:]))), now: 1)
    #expect(store.sessions["s"]?.pending == .question)
    _ = store.apply(DecodedHook(session: ref, event: .toolStart(tool: "AskUserQuestion", input: .null)), now: 2)
    #expect(store.sessions["s"]?.pending == .question)
    #expect(store.sessions["s"]?.botState == .waiting)
}

@Test func toolEndMeansThinking() {
    var store = SessionStore()
    let ref = SessionRef(id: "s", cwd: nil, client: HookClient())
    _ = store.apply(DecodedHook(session: ref, event: .toolStart(tool: "Bash", input: .null)), now: 1)
    #expect(store.sessions["s"]?.botState == .working)
    _ = store.apply(DecodedHook(session: ref, event: .toolEnd(tool: "Bash", ok: true, input: .null, response: .null)), now: 2)
    #expect(store.sessions["s"]?.botState == .thinking)
    _ = store.apply(DecodedHook(session: ref, event: .toolEnd(tool: "Bash", ok: false, input: .null, response: .null)), now: 3)
    #expect(store.sessions["s"]?.botState == .error)
}

@Test func questionViaPermissionReplyShape() throws {
    let line = ClaudeCodeReplies.questionViaPermission(questions: .array([]), answers: ["q": "a"])
    let j = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    let d = j["hookSpecificOutput"]?["decision"]
    #expect(j["hookSpecificOutput"]?["hookEventName"]?.string == "PermissionRequest")
    #expect(d?["behavior"]?.string == "allow")
    #expect(d?["updatedInput"]?["answers"]?["q"]?.string == "a")
}
