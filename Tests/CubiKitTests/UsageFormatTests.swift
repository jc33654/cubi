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

@Test func compactLineAndLevels() {
    let info = StatuslineInfo(fiveHour: UsageWindow(usedPercent: 8, resetsAt: nil), sevenDay: UsageWindow(usedPercent: 18.6, resetsAt: nil))
    #expect(UsageFormat.compactLine(info) == "5h 8% · 7d 18%")
    #expect(UsageFormat.compactLine(StatuslineInfo()) == nil)
    #expect(UsageFormat.compactLine(nil) == nil)
    #expect(UsageFormat.level(49) == .ok)
    #expect(UsageFormat.level(50) == .warn)
    #expect(UsageFormat.level(80) == .hot)
}

@Test func statuslineDoesNotCreateSessions() {
    var store = SessionStore()
    let ref = SessionRef(id: "unknown", cwd: nil, client: HookClient())
    let fx = store.apply(DecodedHook(session: ref, event: .statusline(StatuslineInfo(contextPercent: 10))), now: 1)
    #expect(store.sessions.isEmpty)
    // The account-wide usage is still worth surfacing.
    #expect(fx.contains { if case .usage = $0 { return true }; return false })
}
