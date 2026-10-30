import Foundation
import Testing
@testable import CubiKit

@Test func resetLabelWithin24hIsClockOnly() {
    let now = Date(timeIntervalSince1970: 1_793_167_200)          // 2026-10-28 14:00 Taipei
    let label = UsageFormat.resetLabel(resetsAt: 1_793_176_200, now: now)   // +2.5 h
    #expect(label == "16:30")
}

@Test func resetLabelBeyond24hHasDate() {
    let now = Date(timeIntervalSince1970: 1_793_167_200)
    let label = UsageFormat.resetLabel(resetsAt: 1_793_379_600, now: now)   // 10/31 01:00 Taipei
    #expect(label == "10/31 01:00")
}

@Test func resetLabelPastIsNow() {
    let now = Date(timeIntervalSince1970: 1_793_167_200)
    #expect(UsageFormat.resetLabel(resetsAt: 1_793_167_000, now: now) == "now")
    #expect(UsageFormat.resetLabel(resetsAt: nil, now: now) == nil)
}

@Test func levels() {
    #expect(UsageFormat.level(49) == .ok)
    #expect(UsageFormat.level(50) == .warn)
    #expect(UsageFormat.level(80) == .hot)
}

@Test func statuslineDoesNotCreateSessions() {
    var store = SessionStore()
    let ref = SessionRef(id: "unknown", cwd: nil, client: HookClient())
    let fx = store.apply(DecodedHook(session: ref, event: .statusline(StatuslineInfo(contextPercent: 10, fiveHour: UsageWindow(usedPercent: 3, resetsAt: nil)))), now: 1)
    #expect(store.sessions.isEmpty)
    // The account-wide usage is still worth surfacing.
    #expect(fx.contains { if case .usage = $0 { return true }; return false })
}

@Test func savedUsageFromAnOlderBuildStillDecodes() throws {
    // What a build before SessionStats wrote to UserDefaults: no "session" key.
    let old = Data("""
    {"fiveHour":{"usedPercent":14,"resetsAt":null},"sevenDay":{"usedPercent":30,"resetsAt":1793379600},"costUSD":2.5,"sessionName":"x"}
    """.utf8)
    let info = try JSONDecoder().decode(StatuslineInfo.self, from: old)
    #expect(info.fiveHour?.usedPercent == 14 && info.sevenDay?.resetsAt == 1793379600 && info.costUSD == 2.5)
    #expect(info.session == SessionStats())
    let roundTrip = try JSONDecoder().decode(StatuslineInfo.self, from: JSONEncoder().encode(info))
    #expect(roundTrip == info)
}

@Test func homeIsAbbreviatedOnlyAtAPathBoundary() {
    #expect(PathFormat.abbreviatingHome("/Users/me/x", home: "/Users/me") == "~/x")
    #expect(PathFormat.abbreviatingHome("/Users/me", home: "/Users/me") == "~")
    #expect(PathFormat.abbreviatingHome("/Users/meow/app", home: "/Users/me") == "/Users/meow/app")
}
