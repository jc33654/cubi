import Testing
@testable import CubiKit

private func hook(_ event: CanonicalEvent, id: String? = nil, agent: String? = nil) -> DecodedHook {
    DecodedHook(session: SessionRef(id: "s", cwd: nil, client: HookClient()), event: event, toolUseID: id, agentID: agent)
}
private let toolEnd = CanonicalEvent.toolEnd(tool: "Bash", ok: true, input: .null, response: .null)

@Test func eventsThatEndAPendingRequest() {
    #expect(hook(.stop(lastMessage: nil)).settlesPendingRequest(toolUseID: "t1"))
    #expect(hook(.prompt("x")).settlesPendingRequest(toolUseID: "t1"))
    #expect(hook(.sessionEnd(reason: nil)).settlesPendingRequest(toolUseID: "t1"))
    #expect(hook(toolEnd, id: "t1").settlesPendingRequest(toolUseID: "t1"))
    #expect(hook(.toolStart(tool: "Bash", input: .null), id: "t1").settlesPendingRequest(toolUseID: "t1"))
    // Without ids on either side (manifest plugins), any tool traffic counts.
    #expect(hook(toolEnd).settlesPendingRequest(toolUseID: nil))
    #expect(hook(toolEnd).settlesPendingRequest(toolUseID: "t1"))
    #expect(hook(toolEnd, id: "t1").settlesPendingRequest(toolUseID: nil))
}

@Test func parallelCallsAndSubagentsDoNotEndAPendingRequest() {
    #expect(!hook(toolEnd, id: "t2").settlesPendingRequest(toolUseID: "t1"))
    #expect(!hook(.toolStart(tool: "Bash", input: .null), id: "t2").settlesPendingRequest(toolUseID: "t1"))
    #expect(!hook(toolEnd, id: "t1", agent: "a1").settlesPendingRequest(toolUseID: "t1"))
    #expect(!hook(.subagentStart(type: nil)).settlesPendingRequest(toolUseID: "t1"))
    #expect(!hook(.subagentStop(type: nil)).settlesPendingRequest(toolUseID: nil))
    // These arrive while a request is legitimately still waiting.
    #expect(!hook(.toolStart(tool: "AskUserQuestion", input: .null)).settlesPendingRequest(toolUseID: nil))
    #expect(!hook(.notification(type: "permission_prompt", message: "")).settlesPendingRequest(toolUseID: nil))
    #expect(!hook(.statusline(StatuslineInfo())).settlesPendingRequest(toolUseID: nil))
    #expect(!hook(.permissionRequest(tool: "Bash", input: .null, suggestions: .null)).settlesPendingRequest(toolUseID: nil))
}

@Test func subagentToolHooksCarryTheirAgentID() throws {
    #expect(try Fixtures.decoded("PostToolUse-5").agentID != nil)
    #expect(try Fixtures.decoded("PostToolUse-2").agentID == nil)
}

@Test func handledElsewhereGoesIdle() {
    var store = SessionStore()
    let ref = SessionRef(id: "s", cwd: nil, client: HookClient(), transcriptPath: "/tmp/t.jsonl")
    _ = store.apply(DecodedHook(session: ref, event: .permissionRequest(tool: "Bash", input: .null, suggestions: .null)), now: 1)
    #expect(store.sessions["s"]?.transcriptPath == "/tmp/t.jsonl")
    store.resolvePending("s", outcome: .handledElsewhere)
    #expect(store.sessions["s"]?.botState == .idle)
    #expect(store.sessions["s"]?.pending == nil)
}

@Test func decoderCarriesTranscriptPath() throws {
    let d = try Fixtures.decoded("PermissionRequest-1")
    #expect(d.session.transcriptPath?.hasSuffix(".jsonl") == true)
}
