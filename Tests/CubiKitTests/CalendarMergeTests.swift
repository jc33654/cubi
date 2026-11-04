import Testing
@testable import CubiKit

private func entry(_ start: Double, _ end: Double, marker: String = "sprint:s1:1000", title: String = "DDP-6532 退款優化",
                   notes: String? = "https://jira/browse/DDP-6532") -> PluginIO.CalendarEntry {
    PluginIO.CalendarEntry(title: title, start: start, end: end, notes: notes, marker: marker)
}

private func ours(_ id: String, _ start: Double, _ end: Double, markers: [String], title: String = "DDP-6532 退款優化") -> CalendarMerge.Existing {
    CalendarMerge.Existing(id: id, title: title, start: start, end: end, notes: CalendarMerge.notes(body: "x", markers: markers))
}

@Test func calendarNotesCarryMarkersOnTheLastLine() {
    let notes = CalendarMerge.notes(body: "https://jira/browse/DDP-6532\n", markers: ["a:1", "b:2", "a:1"])
    #expect(notes == "https://jira/browse/DDP-6532\n\n由 Cubi 記錄 · a:1 b:2")
    #expect(CalendarMerge.markers(in: notes) == ["a:1", "b:2"])
    #expect(CalendarMerge.notes(body: nil, markers: ["m"]) == "由 Cubi 記錄 · m")
    #expect(CalendarMerge.markers(in: "午餐會議\n不是我們寫的").isEmpty)
}

@Test func calendarCreatesWhenNothingTouches() {
    let plan = CalendarMerge.plan(entry(1000, 4600), nearby: [
        ours("far", 0, 500, markers: ["sprint:s1:0"]),                 // more than 5 min before
        ours("other", 1000, 4600, markers: ["x"], title: "DDP-9999 別的單"),
        CalendarMerge.Existing(id: "foreign", title: "DDP-6532 退款優化", start: 1000, end: 2000, notes: "同事手動建的"),
    ])
    #expect(plan == .create(title: "DDP-6532 退款優化", start: 1000, end: 4600, notes: "https://jira/browse/DDP-6532\n\n由 Cubi 記錄 · sprint:s1:1000"))
}

@Test func calendarSkipsShortAndAlreadyWritten() {
    #expect(CalendarMerge.plan(entry(1000, 1059), nearby: []) == .skip("不到 1 分鐘"))
    #expect(CalendarMerge.plan(entry(1000, 4600), nearby: [ours("e", 900, 5000, markers: ["sprint:s1:1000"])]) == .skip("已寫過"))
    // A merged event remembers every marker it absorbed.
    #expect(CalendarMerge.plan(entry(1000, 4600), nearby: [ours("e", 900, 9000, markers: ["sprint:s1:800", "sprint:s1:1000"])]) == .skip("已寫過"))
}

@Test func calendarExtendsAnAdjacentEventAndFoldsOthersIn() {
    let before = ours("a", 0, 800, markers: ["sprint:s1:0"])          // ends 200 s before: within the gap
    let after = ours("b", 4800, 6000, markers: ["sprint:s1:4800"])    // starts 200 s after
    let plan = CalendarMerge.plan(entry(1000, 4600), nearby: [after, before])
    #expect(plan == .extend(id: "a", start: 0, end: 6000, notes: "https://jira/browse/DDP-6532\n\n由 Cubi 記錄 · sprint:s1:0 sprint:s1:4800 sprint:s1:1000", remove: ["b"]))
    // Just outside the gap on both sides: a new event.
    let plan2 = CalendarMerge.plan(entry(1000, 4600), nearby: [ours("a", 0, 699, markers: ["m"]), ours("b", 4901, 6000, markers: ["n"])])
    if case .create = plan2 {} else { Issue.record("expected create, got \(plan2)") }
}
