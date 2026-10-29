import Foundation
import Testing
@testable import CubiKit

private func parse(_ line: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

@Test func allowReply() throws {
    let j = try parse(ClaudeCodeReplies.permission(.allow))
    let d = j["hookSpecificOutput"]
    #expect(d?["hookEventName"]?.string == "PermissionRequest")
    #expect(d?["decision"]?["behavior"]?.string == "allow")
    #expect(d?["decision"]?["updatedPermissions"] == nil)
}

@Test func alwaysReplyPassesRecordedSuggestionsThrough() throws {
    let fixture = try Fixtures.decoded("PermissionRequest-1")
    guard case .permissionRequest(_, _, let suggestions) = fixture.event else { Issue.record("x"); return }
    let j = try parse(ClaudeCodeReplies.permission(.always(suggestions: suggestions)))
    let perms = j["hookSpecificOutput"]?["decision"]?["updatedPermissions"]?.array
    #expect(perms?.count == 1)
    #expect(perms?.first?["type"]?.string == "addRules")
    #expect(perms?.first?["destination"]?.string == "localSettings")
    #expect(perms?.first?["rules"]?.array?.first?["ruleContent"]?.string == "curl -s https://example.com")
}

@Test func alwaysWithoutSuggestionsIsPlainAllow() throws {
    let j = try parse(ClaudeCodeReplies.permission(.always(suggestions: .null)))
    #expect(j["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == nil)
    #expect(j["hookSpecificOutput"]?["decision"]?["behavior"]?.string == "allow")
}

@Test func denyReply() throws {
    let j = try parse(ClaudeCodeReplies.permission(.deny(message: "no")))
    #expect(j["hookSpecificOutput"]?["decision"]?["behavior"]?.string == "deny")
    #expect(j["hookSpecificOutput"]?["decision"]?["message"]?.string == "no")
}

@Test func questionReplyEchoesQuestionsAndAnswers() throws {
    let fixture = try Fixtures.decoded("PreToolUse-AskUserQuestion-1")
    guard case .question(let input) = fixture.event else { Issue.record("x"); return }
    let questions = try #require(AskQuestion.parse(input))
    #expect(questions.count == 1)
    #expect(questions[0].options.count == 3)
    let line = ClaudeCodeReplies.question(questions: input["questions"]!, answers: [questions[0].question: questions[0].options[1].label])
    let j = try parse(line)
    let out = j["hookSpecificOutput"]
    #expect(out?["hookEventName"]?.string == "PreToolUse")
    #expect(out?["permissionDecision"]?.string == "allow")
    #expect(out?["updatedInput"]?["questions"]?.array?.count == 1)
    #expect(out?["updatedInput"]?["answers"]?[questions[0].question]?.string == questions[0].options[1].label)
    #expect(!line.contains("\n"))
}

@Test func askQuestionParseRejectsBadShapes() {
    #expect(AskQuestion.parse(.null) == nil)
    #expect(AskQuestion.parse(.object(["questions": .array([])])) == nil)
    #expect(AskQuestion.parse(.object(["questions": .array([.object(["question": .string("q"), "options": .array([])])])])) == nil)
}

@Test func approvalSummaries() {
    let bash = ApprovalSummary.describe(tool: "Bash", input: .object(["command": .string("rm -rf /tmp/x")]))
    #expect(bash.title == "執行指令" && bash.detail == "rm -rf /tmp/x")
    let edit = ApprovalSummary.describe(tool: "Edit", input: .object(["file_path": .string("/a/b.swift")]))
    #expect(edit.detail == "/a/b.swift")
    let other = ApprovalSummary.describe(tool: "Mystery", input: .object(["k": .string("v")]))
    #expect(other.title.contains("Mystery") && other.detail.contains("\"k\""))
}

@Test func resolvePendingClearsAndSetsState() {
    var store = SessionStore()
    let ref = SessionRef(id: "s", cwd: nil, client: HookClient())
    _ = store.apply(DecodedHook(session: ref, event: .permissionRequest(tool: "Bash", input: .null, suggestions: .null)), now: 1)
    #expect(store.anyPending)
    store.resolvePending("s", outcome: .allowed)
    #expect(!store.anyPending)
    #expect(store.sessions["s"]?.botState == .working)
    store.resolvePending("s", outcome: .denied)   // no pending any more: no change
    #expect(store.sessions["s"]?.botState == .working)
}
