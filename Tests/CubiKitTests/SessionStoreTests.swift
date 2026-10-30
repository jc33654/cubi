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
    _ = try feed("SessionStart-2")
    #expect(store.order.count == 1)
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
    #expect(store.sessions[id]?.pending != nil)
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
    let fx = store.apply(hook("s", .statusline(StatuslineInfo(sessionName: "小工具", contextPercent: 91, sevenDay: UsageWindow(usedPercent: 30, resetsAt: nil)))), now: 2)
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

// Every session's status line reports the rate limits its own session last heard; idle ones are
// stale or blank. The island shows one account-wide reading.
@Test func usageMergesAcrossSessions() {
    var store = SessionStore()
    let w = { (p: Double) in UsageWindow(usedPercent: p, resetsAt: nil) }
    _ = store.apply(hook("a", .sessionStart(source: nil)), now: 1)
    _ = store.apply(hook("b", .sessionStart(source: nil)), now: 2)   // b is the active one
    var fx = store.apply(hook("b", .statusline(StatuslineInfo(fiveHour: w(14), sevenDay: w(30)))), now: 3)
    #expect(fx == [.usage(StatuslineInfo(fiveHour: w(14), sevenDay: w(30)))])

    // Idle session a: nil 5h must not blank the reading, stale 7d must not replace it.
    fx = store.apply(hook("a", .statusline(StatuslineInfo(fiveHour: nil, sevenDay: w(5)))), now: 4)
    #expect(fx.isEmpty)
    #expect(store.usage?.fiveHour == w(14))
    #expect(store.usage?.sevenDay == w(30))

    // a becomes active again: its next reading wins.
    _ = store.apply(hook("a", .prompt("hi")), now: 5)
    fx = store.apply(hook("a", .statusline(StatuslineInfo(fiveHour: w(16), sevenDay: nil))), now: 6)
    #expect(store.usage?.fiveHour == w(16))
    #expect(store.usage?.sevenDay == w(30))
    #expect(fx.count == 1)

    // A session without a robot only fills blanks.
    _ = store.apply(hook("z", .statusline(StatuslineInfo(fiveHour: w(99), sevenDay: w(99)))), now: 7)
    #expect(store.usage?.fiveHour == w(16))
    #expect(store.sessions["z"] == nil)
}

@Test func seededUsageFillsBlanksOnly() {
    var store = SessionStore()
    let w = { (p: Double) in UsageWindow(usedPercent: p, resetsAt: nil) }
    store.seedUsage(StatuslineInfo(fiveHour: w(10), sevenDay: w(20)))
    _ = store.apply(hook("z", .statusline(StatuslineInfo(fiveHour: nil, sevenDay: nil))), now: 1)
    #expect(store.usage?.fiveHour == w(10))
    _ = store.apply(hook("a", .sessionStart(source: nil)), now: 2)
    _ = store.apply(hook("a", .statusline(StatuslineInfo(fiveHour: w(11)))), now: 3)
    #expect(store.usage?.fiveHour == w(11))
    #expect(store.usage?.sevenDay == w(20))
}

@Test func lateSubagentStopDoesNotWakeAnIdleRobot() {
    var store = SessionStore()
    _ = store.apply(hook("s", .sessionStart(source: nil)), now: 1)
    _ = store.apply(hook("s", .prompt("hi")), now: 2)
    _ = store.apply(hook("s", .subagentStart(type: "Explore")), now: 3)
    #expect(store.sessions["s"]?.botState == .working)
    _ = store.apply(hook("s", .subagentStop(type: "Explore")), now: 4)
    #expect(store.sessions["s"]?.botState == .thinking)
    _ = store.apply(hook("s", .stop(lastMessage: nil)), now: 5)
    store.revertToIdle("s")
    #expect(store.sessions["s"]?.botState == .idle)
    _ = store.apply(hook("s", .subagentStop(type: "Explore")), now: 60)
    #expect(store.sessions["s"]?.botState == .idle)
}

@Test func statuslineAfterSessionEndDoesNotResurrect() {
    var store = SessionStore()
    _ = store.apply(hook("s", .sessionStart(source: nil)), now: 1)
    _ = store.apply(hook("s", .sessionEnd(reason: nil)), now: 2)
    #expect(store.sessions["s"]?.ended == true)
    _ = store.apply(hook("s", .statusline(StatuslineInfo(contextPercent: 10))), now: 3)
    #expect(store.sessions["s"]?.ended == true)
}

@Test func costChangesStillReachTheIslandButAreNotWindowChanges() {
    var store = SessionStore()
    let w = UsageWindow(usedPercent: 14, resetsAt: nil)
    _ = store.apply(hook("a", .sessionStart(source: nil)), now: 1)
    _ = store.apply(hook("a", .statusline(StatuslineInfo(fiveHour: w, costUSD: 1.0))), now: 2)
    let fx = store.apply(hook("a", .statusline(StatuslineInfo(fiveHour: w, costUSD: 1.5))), now: 3)
    #expect(fx == [.usage(StatuslineInfo(fiveHour: w, costUSD: 1.5))])
    #expect(!SessionStore.windowsChanged(from: StatuslineInfo(fiveHour: w, costUSD: 1.0), to: StatuslineInfo(fiveHour: w, costUSD: 1.5)))
    #expect(store.apply(hook("a", .statusline(StatuslineInfo(fiveHour: w, costUSD: 1.5))), now: 4).isEmpty)
}

@Test func sessionKeepsCountsAndStatuslineStats() {
    var store = SessionStore()
    _ = store.apply(hook("s", .sessionStart(source: nil)), now: 100)
    _ = store.apply(hook("s", .prompt("hi")), now: 101)
    _ = store.apply(hook("s", .toolStart(tool: "Bash", input: .null)), now: 102)
    _ = store.apply(hook("s", .toolStart(tool: "AskUserQuestion", input: .null)), now: 103)   // not a tool call
    _ = store.apply(hook("s", .prompt("again")), now: 104)
    let stats = SessionStats(modelDisplayName: "Opus", projectDir: "/p", version: "2.1.312", totalDurationMS: 5000, linesAdded: 3)
    _ = store.apply(hook("s", .statusline(StatuslineInfo(costUSD: 1.25, session: stats))), now: 105)
    _ = store.apply(hook("s", .statusline(StatuslineInfo(session: SessionStats(apiDurationMS: 900)))), now: 106)
    let s = store.sessions["s"]!
    #expect(s.startedAt == 100)
    #expect(s.prompts == 2 && s.toolCalls == 1)
    #expect(s.costUSD == 1.25)
    #expect(s.stats.modelDisplayName == "Opus" && s.stats.projectDir == "/p" && s.stats.version == "2.1.312")
    #expect(s.stats.totalDurationMS == 5000 && s.stats.apiDurationMS == 900 && s.stats.linesAdded == 3)   // merged, not replaced
}
