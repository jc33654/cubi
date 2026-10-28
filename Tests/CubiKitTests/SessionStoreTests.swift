import Testing
@testable import CubiKit

private func hook(_ id: String, _ event: CanonicalEvent, cwd: String? = "/Users/me/Documents/cubi") -> DecodedHook {
    DecodedHook(session: SessionRef(id: id, cwd: cwd, client: HookClient(termProgram: "ghostty")), event: event)
}

/// All fixtures below belong to the same recorded session (7696156f…, default permission mode).
@Test func lifecycleFromRealFixtures() throws {
    var store = SessionStore()
    var t = 1000.0
    func feed(_ name: String) throws -> [StoreEffect] {
        t += 1
        return store.apply(try Fixtures.decoded(name), now: t)
    }
    let added = try feed("SessionStart-2")
    #expect(added.contains { if case .added = $0 { return true }; return false })
    let id = store.order[0]
    #expect(store.sessions[id]?.botState == .idle)
    #expect(store.sessions[id]?.name == "cubi")   // cwd basename

    _ = try feed("UserPromptSubmit-2")
    #expect(store.sessions[id]?.botState == .thinking)

    _ = try feed("PreToolUse-2")
    #expect(store.sessions[id]?.botState == .working)
    #expect(store.sessions[id]?.ticker.hasPrefix("curl") == true)

    let fx = try feed("PermissionRequest-1")
    #expect(store.sessions[id]?.botState == .waiting)
    #expect(store.sessions[id]?.waitingBadge == .exclaim)
    #expect(store.anyPending)
    #expect(fx.contains { if case .notify = $0 { return true }; return false })

    _ = try feed("PostToolUse-2")
    #expect(store.sessions[id]?.pending == nil)

    let stop = try feed("Stop-2")
    #expect(store.sessions[id]?.botState == .happy)
    #expect(stop.contains { if case .revertToIdle(id, after: SessionStore.happyDuration) = $0 { return true }; return false })
    store.revertToIdle(id)
    #expect(store.sessions[id]?.botState == .idle)

    let end = try feed("SessionEnd-2")
    #expect(store.sessions[id]?.ended == true)
    #expect(end.contains { if case .removeLater(id, _) = $0 { return true }; return false })
    store.remove(id)
    #expect(store.sessions.isEmpty && store.order.isEmpty)
}

@Test func twoSessionsGetDistinctColoursAndKeepOrder() {
    var store = SessionStore()
    _ = store.apply(hook("aaaa-1111", .sessionStart(source: "startup")), now: 1)
    _ = store.apply(hook("bbbb-2222", .sessionStart(source: "startup"), cwd: "/tmp/other"), now: 2)
    let a = store.sessions["aaaa-1111"]!, b = store.sessions["bbbb-2222"]!
    #expect(a.colorIndex != b.colorIndex)
    #expect(store.order == ["aaaa-1111", "bbbb-2222"])
    #expect(b.name == "other")
}

@Test func questionViaPermissionFlowIsAQuestion() {
    var store = SessionStore()
    _ = store.apply(hook("s", .permissionRequest(tool: "AskUserQuestion", input: .null, suggestions: .null)), now: 1)
    #expect(store.sessions["s"]?.pending == .question)
    #expect(store.sessions["s"]?.waitingBadge == .question)
}

@Test func statuslineNamesAndTires() {
    var store = SessionStore()
    _ = store.apply(hook("s", .sessionStart(source: nil)), now: 1)
    let fx = store.apply(hook("s", .statusline(StatuslineInfo(sessionName: "小工具", contextPercent: 91))), now: 2)
    #expect(store.sessions["s"]?.name == "小工具")
    #expect(store.sessions["s"]?.botState == .tired)
    #expect(store.sessions["s"]?.contextPercent == 91)
    #expect(fx.contains { if case .usage = $0 { return true }; return false })
    // Status line traffic must not keep the session "awake".
    #expect(store.sessions["s"]?.lastEventAt == 1)
}

@Test func sleepsAfterTenIdleMinutes() {
    var store = SessionStore()
    _ = store.apply(hook("s", .sessionStart(source: nil)), now: 0)
    store.tick(now: 599)
    #expect(store.sessions["s"]?.botState == .idle)
    store.tick(now: 600)
    #expect(store.sessions["s"]?.botState == .sleeping)
    _ = store.apply(hook("s", .prompt("hi")), now: 601)
    #expect(store.sessions["s"]?.botState == .thinking)
}

@Test func sessionEndForUnknownSessionIsIgnored() {
    var store = SessionStore()
    #expect(store.apply(hook("ghost", .sessionEnd(reason: "other")), now: 1).isEmpty)
    #expect(store.sessions.isEmpty)
}
