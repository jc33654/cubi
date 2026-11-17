import Foundation
import Testing
@testable import CubiKit

/// Batch 38: 專注零件. A fixed time zone, so midnight is where these tests say it is.
private let taipei: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Taipei")!
    return c
}()
/// 2026-11-17 09:00 in Taipei, as reference-date seconds.
private let nine = taipei.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9))!.timeIntervalSinceReferenceDate
private let minute = 60.0

private func span(_ from: Double, _ to: Double) -> FocusLog.Span { FocusLog.Span(start: nine + from * minute, end: nine + to * minute) }

private func hook(_ id: String, _ event: CanonicalEvent, restricted: Bool? = nil) -> DecodedHook {
    DecodedHook(session: SessionRef(id: id, cwd: "/Users/me/proj", client: HookClient(termProgram: "ghostty", restricted: restricted)), event: event)
}

private func today(_ log: FocusLog) -> FocusLog.Day { log.today(now: nine + 12 * 3600, calendar: taipei) }

@Test func aGearIsTwentyFiveMinutesNotOneLess() {
    for (minutes, gears) in [(24.0, 0), (25.0, 1), (26.0, 1), (49.0, 1), (50.0, 2)] {
        var log = FocusLog()
        log.add([span(0, minutes)], since: 0, now: nine + 3600 * 3, calendar: taipei)
        #expect(today(log).gears == gears, "\(minutes) min")
    }
    var log = FocusLog()
    log.add([span(0, 26)], since: 0, now: nine + 3600, calendar: taipei)
    #expect(today(log).untilNext == 24 * minute)
}

@Test func twoSessionsAtOnceCountOnce() {
    var log = FocusLog()
    log.add([span(0, 20), span(10, 30)], since: 0, now: nine + 3600, calendar: taipei)   // 0–30 busy
    #expect(today(log).seconds == 30 * minute)
    #expect(log.days["2026-11-17"] == [span(0, 30)])
    // The same minutes reported again (every tick sends them all) change nothing.
    log.add([span(0, 20), span(10, 30)], since: 0, now: nine + 3600, calendar: taipei)
    #expect(today(log).seconds == 30 * minute)
}

@Test func pausesAddUpRatherThanStartOver() {
    var log = FocusLog()
    log.add([span(0, 15), span(40, 50)], since: 0, now: nine + 3600, calendar: taipei)   // 15 + 10 after a long pause
    #expect(today(log).gears == 1)
}

@Test func aPauseOfTenMinutesSplitsTheStretchAndTheGapIsNotBusy() {
    func busy(_ eventsInMinutes: [Double]) -> FocusLog.Day {
        var store = SessionStore()
        for (i, m) in eventsInMinutes.enumerated() { _ = store.apply(hook("s", .prompt("\(i)")), now: nine + m * minute) }
        var log = FocusLog()
        log.add(FocusLog.spans(of: Array(store.sessions.values)), since: 0, now: nine + 3600, calendar: taipei)
        return today(log)
    }
    // 15 busy minutes, then a pause just under the gap: one stretch, the silent minutes inside it count.
    #expect(busy([0, 5, 10, 15, 15 + 599 / minute]).seconds == 15 * minute + 599)
    // The same pause at the gap: two stretches, the ten silent minutes are not busy, the rest adds up.
    let split = busy([0, 5, 10, 15, 25, 30, 35])
    #expect(split.seconds == 25 * minute)
    #expect(split.gears == 1)
}

@Test func aSpanOverMidnightIsCutAndNothingCarriesOver() {
    var log = FocusLog()
    log.add([span(14 * 60 + 40, 15 * 60 + 20)], since: 0, now: nine + 20 * 3600, calendar: taipei)   // 23:40–00:20
    #expect(log.day("2026-11-17").seconds == 20 * minute)
    #expect(log.day("2026-11-18").seconds == 20 * minute)
    #expect(log.day("2026-11-17").gears == 0 && log.day("2026-11-18").gears == 0)
}

@Test func restrictedSessionsAreClaudeWorkingAloneAndDoNotCount() {
    var store = SessionStore()
    _ = store.apply(hook("mine", .prompt("a")), now: nine)
    _ = store.apply(hook("mine", .prompt("b")), now: nine + 5 * minute)
    _ = store.apply(hook("estimate", .prompt("a"), restricted: true), now: nine)
    _ = store.apply(hook("estimate", .prompt("b"), restricted: true), now: nine + 40 * minute)
    #expect(FocusLog.spans(of: Array(store.sessions.values)) == [span(0, 5)])
}

@Test func nothingBeforeCountingWasSwitchedOnIsAdded() {
    var log = FocusLog()
    log.add([span(0, 60)], since: nine + 40 * minute, now: nine + 3600, calendar: taipei)
    #expect(today(log).seconds == 20 * minute)
    // Nor anything after now (an open stretch's end is its last event, never later).
    log = FocusLog()
    log.add([span(0, 60)], since: 0, now: nine + 30 * minute, calendar: taipei)
    #expect(today(log).seconds == 30 * minute)
}

@Test func ninetyDaysAreKeptAndRecentListsEveryDay() {
    var log = FocusLog(days: ["2026-08-01": [span(0, 1)], "2026-08-19": [span(0, 1)], "2026-11-16": [FocusLog.Span(start: nine - 86400, end: nine - 86400 + 3000)]])
    log.add([span(0, 30)], since: 0, now: nine + 3600, calendar: taipei)
    #expect(log.days.keys.sorted() == ["2026-08-19", "2026-11-16", "2026-11-17"])
    let recent = log.recent(3, now: nine + 3600, calendar: taipei)
    #expect(recent.map(\.date) == ["2026-11-17", "2026-11-16", "2026-11-15"])
    #expect(recent.map(\.gears) == [1, 2, 0])
}

@Test func theLogSurvivesAsJSON() throws {
    var log = FocusLog()
    log.add([span(0, 30)], since: 0, now: nine + 3600, calendar: taipei)
    let back = try JSONDecoder().decode(FocusLog.self, from: JSONEncoder().encode(log))
    #expect(back == log)
}
