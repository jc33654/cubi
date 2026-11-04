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
    let s = PluginIO.SessionInput(id: "s1", name: "退款優化", cwd: "/Users/me/DDPAY", projectDirectory: nil, agent: "claude-code",
                                  segments: [.init(start: 100, end: 200, open: false), .init(start: 300, end: 330, open: true)])
    #expect(s.json() == #"{"agent":"claude-code","cwd":"/Users/me/DDPAY","id":"s1","name":"退款優化","segments":[{"end":200,"open":false,"start":100},{"end":330,"open":true,"start":300}]}"#)
    let t = PluginIO.TickInput(now: 400, sessions: [s])
    #expect(t.json().hasPrefix(#"{"now":400,"sessions":[{"agent""#))
}

@Test func widgetOutputParsesRowsActionsAndLinks() throws {
    let out = try PluginIO.WidgetOutput.parse(#"""
    {"title":"Sprint",
     "rows":[["今日","2h 35m"],{"label":"DDP-6532","value":"退款優化 v3 入口","url":"https://jira.example/browse/DDP-6532"},{"label":"x","value":"y"}],
     "actions":[{"label":"同步 Jira","action":"sync"}],
     "error":"Jira 認證失敗"}
    """#, tool: try tool())
    #expect(out.title == "Sprint" && out.error == "Jira 認證失敗")
    #expect(out.rows == [.init(label: "今日", value: "2h 35m", url: nil),
                         .init(label: "DDP-6532", value: "退款優化 v3 入口", url: "https://jira.example/browse/DDP-6532"),
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
}

@Test func tickOutputValidatesCalendarEntries() throws {
    let out = try PluginIO.TickOutput.parse(#"""
    {"calendar":[{"title":"DDP-6532 退款優化","start":1762218720,"end":1762228000,"notes":"https://jira/browse/DDP-6532","marker":"sprint:3d22:1762218720"}]}
    """#)
    #expect(out.calendar == [.init(title: "DDP-6532 退款優化", start: 1762218720, end: 1762228000, notes: "https://jira/browse/DDP-6532", marker: "sprint:3d22:1762218720")])
    #expect(try PluginIO.TickOutput.parse("{}").calendar.isEmpty)
    #expect(throws: PluginIO.ParseError.badCalendar(1, "缺 title")) { try PluginIO.TickOutput.parse(#"{"calendar":[{"start":1,"end":2,"marker":"m"}]}"#) }
    #expect(throws: PluginIO.ParseError.badCalendar(1, "start/end 不合法")) { try PluginIO.TickOutput.parse(#"{"calendar":[{"title":"t","start":2,"end":2,"marker":"m"}]}"#) }
    #expect(throws: PluginIO.ParseError.badCalendar(2, "marker 只能有英數、:._-，1–80 字")) {
        try PluginIO.TickOutput.parse(#"{"calendar":[{"title":"t","start":1,"end":2,"marker":"ok"},{"title":"t","start":1,"end":2,"marker":"有 空白"}]}"#)
    }
    #expect(PluginIO.isValidMarker("sprint:manual:0f3a-1") && !PluginIO.isValidMarker("") && !PluginIO.isValidMarker(String(repeating: "a", count: 81)))
}
