import Testing
import Foundation
@testable import CubiKit

private func tool() throws -> ToolPlugin {
    try ToolPlugin.parse(try JSONDecoder().decode(JSONValue.self, from: Data(#"""
    {"id":"t","name":"T","panel":{"file":"a"},"commands":{
      "session.info": {"run": ["$plugin/t.py"], "args": ["text"], "stdin": 1},
      "sync":         {"run": ["$plugin/t.py"], "args": ["text"], "stdin": 1},
      "reveal":       {"run": ["$plugin/t.py"], "args": ["text"], "stdin": 1, "reveal": true},
      "plain":        {"run": ["$plugin/t.py"]}
    }}
    """#.utf8)), baseDirectory: "/p", home: "/Users/me")
}

@Test func sessionInputEncodesSortedAndOmitsMissingPaths() {
    let s = PluginIO.SessionInput(id: "s1", name: "範例工單", cwd: "/Users/me/proj", projectDirectory: nil, agent: "claude-code",
                                  segments: [.init(start: 100, end: 200, open: false), .init(start: 300, end: 330, open: true)])
    #expect(s.json() == #"{"agent":"claude-code","cwd":"/Users/me/proj","id":"s1","name":"範例工單","segments":[{"end":200,"open":false,"start":100},{"end":330,"open":true,"start":300}]}"#)
    let t = PluginIO.TickInput(now: 400, sessions: [s])
    #expect(t.json().hasPrefix(#"{"now":400,"sessions":[{"agent""#))
}

@Test func widgetOutputParsesRowsActionsAndLinks() throws {
    let out = try PluginIO.WidgetOutput.parse(#"""
    {"title":"Sprint",
     "rows":[["今日","2h 35m"],{"label":"PROJ-12","value":"範例工單 甲","url":"https://jira.example/browse/PROJ-12"},{"label":"x","value":"y"}],
     "actions":[{"label":"同步 Jira","action":"sync"}],
     "error":"Jira 認證失敗"}
    """#, tool: try tool())
    #expect(out.title == "Sprint" && out.error == "Jira 認證失敗")
    #expect(out.rows == [.init(label: "今日", value: "2h 35m", url: nil),
                         .init(label: "PROJ-12", value: "範例工單 甲", url: "https://jira.example/browse/PROJ-12"),
                         .init(label: "x", value: "y", url: nil)])
    #expect(out.actions == [.init(label: "同步 Jira", action: "sync", input: nil)])
    let bare = try PluginIO.WidgetOutput.parse(#"{"rows":[]}"#, tool: try tool())
    #expect(bare.rows.isEmpty && bare.actions.isEmpty && bare.title == nil)
    // An action that wants a line from the user carries the prompt to show.
    let asking = try PluginIO.WidgetOutput.parse(#"{"actions":[{"label":"綁單號…","action":"sync","input":"單號（可多個，用空白隔開）"}]}"#, tool: try tool())
    #expect(asking.actions == [.init(label: "綁單號…", action: "sync", input: "單號（可多個，用空白隔開）", arg: nil)])
    // A button with a value of its own: passed as input, nobody is asked; an empty prompt is no prompt.
    let fixed = try PluginIO.WidgetOutput.parse(#"{"actions":[{"label":"解除 PROJ-1","action":"sync","arg":"PROJ-1","input":""}]}"#, tool: try tool())
    #expect(fixed.actions == [.init(label: "解除 PROJ-1", action: "sync", input: nil, arg: "PROJ-1")])
    #expect(PluginIO.SessionInput(id: "s", name: "n", cwd: nil, projectDirectory: nil, agent: "a", segments: [], input: "PROJ-1 PROJ-2").json()
            == #"{"agent":"a","id":"s","input":"PROJ-1 PROJ-2","name":"n","segments":[]}"#)
    #expect(PluginIO.cleanInput("  PROJ-1\tPROJ-2\nPROJ-3\u{7} ") == "PROJ-1 PROJ-2 PROJ-3" && PluginIO.cleanInput(" \n ") == nil)
    #expect(PluginIO.cleanInput(String(repeating: "a", count: 600))?.count == PluginIO.inputLimit)
}

@Test func widgetRowsCarryToneProgressAndClock() throws {
    let now = 1_762_300_000.0
    let out = try PluginIO.WidgetOutput.parse(#"""
    {"rows":[
      {"label":"PROJ-1","value":"剩 12h","tone":"warning","progress":0.4,"clock":{"since":1762299000,"offset":43200,"down":true}},
      {"label":"a","value":"b","tone":"purple","progress":1.5,"clock":{"since":"x"}},
      {"label":"c","value":"d","clock":{"since":1e300}},
      {"label":"e","value":"f","clock":{"since":1762399999,"offset":0}},
      {"label":"g","value":"h","clock":{"since":1762299000,"offset":1e300}}
    ],
     "actions":[{"label":"開始計時","action":"sync","icon":"play.fill"},{"label":"x","action":"sync","icon":"Bad Name!"}]}
    """#, tool: try tool(), now: now)
    let r = out.rows
    #expect(r[0].tone == .warning && r[0].progress == 0.4)
    #expect(r[0].clock == .init(since: 1762299000, offset: 43200, down: true))
    #expect(abs((r[0].clock?.seconds(at: now) ?? 0) - 42_200) < 0.001)
    // Unknown tone, progress out of range, unusable clock: dropped, the row stays.
    #expect(r[1].tone == nil && r[1].progress == nil && r[1].clock == nil && r[1].value == "b")
    #expect(r[2].clock == nil)                                  // a since far from now
    // A since in the future stays put: the clock holds at offset until then, every reparse alike.
    #expect(r[3].clock?.since == 1762399999 && r[3].clock?.seconds(at: now) == 0)
    #expect(r[4].clock == nil)                                  // an absurd offset
    #expect(out.actions.map(\.icon) == ["play.fill", nil])
    #expect(PluginIO.WidgetOutput.Clock(since: 0, offset: 60, down: true).seconds(at: 100) == -40)
    let read = PluginIO.WidgetOutput.Clock.reading
    // 00:00 shows once: rounded up while above zero, down past it.
    #expect(read(0.6, true) == "剩 00:01" && read(0, true) == "剩 00:00" && read(-0.4, true) == "超 00:00" && read(-61, true) == "超 01:01")
    #expect(read(3599.9, true) == "剩 1h 0m" && read(45_000, true) == "剩 12h 30m" && read(-3700, true) == "超 1h 1m")
    #expect(read(760, false) == "00:12:40" && read(-300, false) == "−00:05:00")
    #expect(PluginIO.WidgetOutput.Clock.parse(.object(["since": .number(.nan)]), now: 0) == nil)
    #expect(PluginIO.isValidSymbol("clock.arrow.circlepath") && PluginIO.isValidSymbol("a"))
    #expect(["", "A", ".", "..", "a..b", ".a", "a.", "play fill"].allSatisfy { !PluginIO.isValidSymbol($0) })
}

@Test func widgetOutputCapsAndRejects() throws {
    let t = try tool()
    let many = (1...15).map { #"["r\#($0)","v"]"# }.joined(separator: ",")
    #expect(try PluginIO.WidgetOutput.parse(#"{"rows":[\#(many)]}"#, tool: t).rows.count == PluginIO.maxRows)
    let long = String(repeating: "值", count: 300)
    #expect(try PluginIO.WidgetOutput.parse(#"{"rows":[["k","\#(long)"]]}"#, tool: t).rows[0].value.count == PluginIO.valueLimit)
    #expect(throws: PluginIO.ParseError.notJSON("not json")) { try PluginIO.WidgetOutput.parse("not json", tool: t) }
    #expect(throws: PluginIO.ParseError.notJSON("[1]")) { try PluginIO.WidgetOutput.parse("[1]", tool: t) }
    #expect(throws: PluginIO.ParseError.tooLarge) { try PluginIO.WidgetOutput.parse(String(repeating: " ", count: PluginIO.stdoutLimit + 1), tool: t) }
    #expect(throws: PluginIO.ParseError.badRow(1)) { try PluginIO.WidgetOutput.parse(#"{"rows":[["only-one"]]}"#, tool: t) }
    #expect(throws: PluginIO.ParseError.badRow(2)) { try PluginIO.WidgetOutput.parse(#"{"rows":[["a","b"],{"label":"x","value":"y","url":"file:///etc/passwd"}]}"#, tool: t) }
    #expect(throws: PluginIO.ParseError.badAction("「plain」不是這個插件的 hook 命令")) { try PluginIO.WidgetOutput.parse(#"{"actions":[{"label":"x","action":"plain"}]}"#, tool: t) }
    #expect(throws: PluginIO.ParseError.badAction("「reveal」不是這個插件的 hook 命令")) { try PluginIO.WidgetOutput.parse(#"{"actions":[{"label":"x","action":"reveal"}]}"#, tool: t) }
    #expect(throws: PluginIO.ParseError.badAction("缺 label 或 action")) { try PluginIO.WidgetOutput.parse(#"{"actions":[{"label":"x"}]}"#, tool: t) }
    let manyActions = (1...8).map { #"{"label":"a\#($0)","action":"sync"}"# }.joined(separator: ",")
    #expect(try PluginIO.WidgetOutput.parse(#"{"actions":[\#(manyActions)]}"#, tool: t).actions.count == PluginIO.maxActions)
}

@Test func tickOutputValidatesCalendarEntries() throws {
    let out = try PluginIO.TickOutput.parse(#"""
    {"calendar":[{"title":"PROJ-12 範例工單","start":1762218720,"end":1762228000,"notes":"https://jira/browse/PROJ-12","marker":"sprint:s1:1762218720"}]}
    """#, now: 1762230000)
    #expect(out.calendar == [.init(title: "PROJ-12 範例工單", start: 1762218720, end: 1762228000, notes: "https://jira/browse/PROJ-12", marker: "sprint:s1:1762218720")])
    #expect(out.problems.isEmpty)
    #expect(try PluginIO.TickOutput.parse("{}") == .init(calendar: [], problems: []))
    // One bad entry is dropped and named; the good ones around it still count.
    let span = "start/end 不合法（要 start < end，且不超過 24 小時）"
    let mixed = try PluginIO.TickOutput.parse(#"""
    {"calendar":[{"start":1,"end":2,"marker":"m"},
                 {"title":"t","start":2,"end":2,"marker":"m"},
                 {"title":"t","start":0,"end":1e12,"marker":"m"},
                 {"title":"ms","start":1762218720000,"end":1762218720600,"marker":"m"},
                 {"title":"t","start":1,"end":2,"marker":"有 空白"},
                 {"title":"ok","start":100,"end":200,"marker":"ok"}]}
    """#, now: 0)
    #expect(mixed.calendar.map(\.title) == ["ok"])
    #expect(mixed.problems == ["calendar[1]：缺 title", "calendar[2]：\(span)", "calendar[3]：\(span)",
                               "calendar[4]：start 要在現在前後一年內（秒，不是毫秒）", "calendar[5]：marker 只能有英數、:._-，1–80 字"])
    let tooMany = (1...51).map { #"{"title":"t","start":\#($0),"end":\#($0 + 100),"marker":"m\#($0)"}"# }.joined(separator: ",")
    let capped = try PluginIO.TickOutput.parse(#"{"calendar":[\#(tooMany)]}"#, now: 0)
    #expect(capped.calendar.count == 50 && capped.problems == ["calendar 有 51 筆，只收前 50 筆"])
    #expect(PluginIO.isValidMarker("sprint:manual:0f3a-1") && !PluginIO.isValidMarker("") && !PluginIO.isValidMarker(String(repeating: "a", count: 81)))
}

@Test func widgetRowCarriesOneActionCheckedLikeTheOthers() throws {
    let t = try tool()
    let out = try PluginIO.WidgetOutput.parse(#"""
        {"rows":[{"label":"PROJ-1","value":"剩 2h","action":{"label":"解除 PROJ-1","action":"sync","arg":"PROJ-1","icon":"xmark"}},
                 {"label":"今日","value":"1h"}, ["工單","未綁定"]]}
        """#, tool: t)
    #expect(out.rows[0].action == .init(label: "解除 PROJ-1", action: "sync", input: nil, arg: "PROJ-1", icon: "xmark"))
    // Rows from plugins that know nothing of it decode as before.
    #expect(out.rows[1].action == nil && out.rows[2].action == nil)
    #expect(try PluginIO.WidgetOutput.parse(#"{"rows":[{"label":"a","value":"b","action":null}]}"#, tool: t).rows[0].action == nil)
    #expect(throws: PluginIO.ParseError.badAction("「plain」不是這個插件的 hook 命令")) {
        try PluginIO.WidgetOutput.parse(#"{"rows":[{"label":"a","value":"b","action":{"label":"x","action":"plain"}}]}"#, tool: t)
    }
    #expect(throws: PluginIO.ParseError.badAction("缺 label 或 action")) {
        try PluginIO.WidgetOutput.parse(#"{"rows":[{"label":"a","value":"b","action":{"action":"sync"}}]}"#, tool: t)
    }
    // Same rules as the section's buttons: an input prompt drops arg, a bad icon is dropped, a bad arg too.
    let asks = try PluginIO.WidgetOutput.parse(#"{"rows":[{"label":"a","value":"b","action":{"label":"x","action":"sync","input":"單號？","arg":"P-1","icon":"no such"}}]}"#, tool: t)
    #expect(asks.rows[0].action == .init(label: "x", action: "sync", input: "單號？", arg: nil, icon: nil))
    let control = try PluginIO.WidgetOutput.parse(#"{"rows":[{"label":"a","value":"b","action":{"label":"x","action":"sync","arg":"P-1\u0007"}}]}"#, tool: t)
    let section = try PluginIO.WidgetOutput.parse(#"{"actions":[{"label":"x","action":"sync","arg":"P-1\u0007"}]}"#, tool: t)
    #expect(control.rows[0].action?.arg == section.actions[0].arg)
}
