import Testing
@testable import CubiKit

@Test func eventsThatEndAPendingRequest() {
    #expect(CanonicalEvent.toolEnd(tool: "Bash", ok: true, input: .null, response: .null).endsPendingRequest)
    #expect(CanonicalEvent.stop(lastMessage: nil).endsPendingRequest)
    #expect(CanonicalEvent.prompt("x").endsPendingRequest)
    #expect(CanonicalEvent.toolStart(tool: "Bash", input: .null).endsPendingRequest)
    // These arrive while a request is legitimately still waiting.
    #expect(!CanonicalEvent.toolStart(tool: "AskUserQuestion", input: .null).endsPendingRequest)
    #expect(!CanonicalEvent.notification(type: "permission_prompt", message: "").endsPendingRequest)
    #expect(!CanonicalEvent.statusline(StatuslineInfo()).endsPendingRequest)
    #expect(!CanonicalEvent.permissionRequest(tool: "Bash", input: .null, suggestions: .null).endsPendingRequest)
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
