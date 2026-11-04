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
    #expect(out.actions == [.init(label: "同步 Jira", action: "sync")])
    let bare = try PluginIO.WidgetOutput.parse(#"{"rows":[]}"#, tool: try tool())
    #expect(bare.rows.isEmpty && bare.actions.isEmpty && bare.title == nil)
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
