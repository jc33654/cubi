import Testing
import Foundation
@testable import CubiKit

private let home = "/Users/me"

private func parse(_ json: String) throws -> ToolPlugin {
    try ToolPlugin.parse(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), baseDirectory: "/plugins/t", home: home)
}

private let sample = #"""
{
  "kind": "tool", "id": "t", "name": "Tool",
  "panel": { "file": "~/.t/panel/index.html", "width": 800, "height": 500, "bridge": "legacy" },
  "commands": {
    "status":      { "run": ["~/.t/bin/cli", "status", "--json"] },
    "skill.on":    { "run": ["~/.t/bin/cli", "skill", "on", "$1"], "args": ["name"] },
    "config.set":  { "run": ["/usr/local/bin/cli", "config", "set", "$1", "$2"], "args": ["name", "value"] },
    "asset.write": { "run": ["/usr/local/bin/cli", "edit", "write", "$1", "$2"], "args": [{ "enum": ["skills", "rules"] }, "name", "text"], "stdin": 3 },
    "asset.reveal":{ "run": ["/usr/local/bin/cli", "edit", "path", "$1", "$2"], "args": [{ "enum": ["skills"] }, "name"], "reveal": true }
  }
}
"""#

@Test func toolManifestParsesPathsAndCommands() throws {
    let t = try parse(sample)
    #expect(t.id == "t" && t.displayName == "Tool")
    #expect(t.panel.file == "/Users/me/.t/panel/index.html" && t.panel.bridge == "legacy" && t.panel.width == 800)
    #expect(t.commands["status"]?.run == ["/Users/me/.t/bin/cli", "status", "--json"])
    #expect(t.commands["asset.write"]?.stdin == 3 && t.commands["asset.reveal"]?.reveal == true)
    #expect(t.commands["asset.write"]?.args == [.choice(["skills", "rules"]), .name, .text])
}

@Test func toolManifestDefaultsAndRelativePanel() throws {
    let t = try parse(#"{"id":"t","name":"T","panel":{"file":"index.html"},"commands":{}}"#)
    #expect(t.panel.file == "/plugins/t/index.html")
    #expect(t.panel.bridge == "cubi" && t.panel.width == 900 && t.panel.height == 640)
}

@Test func toolManifestRejectsBadShapes() {
    func fails(_ json: String, _ expected: ToolPlugin.LoadError) {
        #expect(throws: expected) { try parse(json) }
    }
    fails(#"{"id":"T!","name":"T","panel":{"file":"a"}}"#, .badID("T!"))
    fails(#"{"id":"t","name":"T"}"#, .missingField("panel.file"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":[]}}}"#, .badCommand("x", "run 要是非空的字串陣列"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":[""]}}}"#, .badCommand("x", "run 要是非空的字串陣列"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c","$3"],"args":["name"]}}}"#, .badCommand("x", "$3 沒有對應的 args"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c","$1"],"args":["text"]}}}"#, .badCommand("x", "args[0] 是 text，只能經 stdin 傳"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c"],"args":["name"],"stdin":2}}}"#, .badCommand("x", "stdin 要在 1…1"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c","$1"],"args":["text"],"stdin":1}}}"#, .badCommand("x", "$1 已經指定走 stdin"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c"],"args":["path"]}}}"#, .badCommand("x", "args[0] 不認得的型別「path」"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"pick.file":{"run":["/c"]}}}"#, .badCommand("pick.file", "保留給面板內建的選擇器，不能自己定義"))
}

@Test func toolManifestResolvesPluginRelativeCommands() throws {
    let t = try parse(#"""
    {"id":"t","name":"T","panel":{"file":"a"},"commands":{
      "a": {"run": ["cli", "x"]},
      "b": {"run": ["/usr/bin/python3", "$plugin/tool.py", "run", "$plugin"]},
      "c": {"run": ["$plugin/bin/cli"]}
    }}
    """#)
    #expect(t.directory == "/plugins/t")
    #expect(t.commands["a"]?.run == ["/plugins/t/cli", "x"])
    #expect(t.commands["b"]?.run == ["/usr/bin/python3", "/plugins/t/tool.py", "run", "/plugins/t"])
    #expect(t.commands["c"]?.run == ["/plugins/t/bin/cli"])
    #expect(try t.invocation(action: "a", args: []).directory == "/plugins/t")
}

private let hooked = #"""
{"id":"t","name":"T","panel":{"file":"a"},
 "session": {"info": "session.info", "refresh": 30},
 "tick": {"action": "tick"},
 "commands": {
   "session.info": {"run": ["$plugin/t.py", "info"], "args": ["text"], "stdin": 1},
   "tick":         {"run": ["$plugin/t.py", "tick"], "args": ["text"], "stdin": 1},
   "sync":         {"run": ["$plugin/t.py", "sync"], "args": ["text"], "stdin": 1},
   "open":         {"run": ["$plugin/t.py", "open"], "args": ["text"], "stdin": 1, "reveal": true},
   "plain":        {"run": ["$plugin/t.py", "plain"]}
 }}
"""#

@Test func toolManifestParsesSessionAndTickHooks() throws {
    let t = try parse(hooked)
    #expect(t.session == .init(info: "session.info", refresh: 30))
    #expect(t.tick == .init(action: "tick", every: 60))
    #expect(t.isHook("sync") && !t.isHook("open") && !t.isHook("plain") && !t.isHook("missing"))
    let plain = try parse(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{}}"#)
    #expect(plain.session == nil && plain.tick == nil)
}

@Test func toolManifestRejectsBadHooks() {
    func fails(_ json: String, _ expected: ToolPlugin.LoadError) {
        #expect(throws: expected) { try parse(json) }
    }
    let cmds = #""commands":{"h":{"run":["/c"],"args":["text"],"stdin":1},"p":{"run":["/c"]},"r":{"run":["/c"],"args":["text"],"stdin":1,"reveal":true}}"#
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"session":{},\#(cmds)}"#, .missingField("session.info"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"session":{"info":"nope"},\#(cmds)}"#, .badHook("session.info", "沒有這個命令「nope」"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"session":{"info":"p"},\#(cmds)}"#, .badHook("session.info", "「p」要宣告 args: [\"text\"], stdin: 1"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"session":{"info":"r"},\#(cmds)}"#, .badHook("session.info", "「r」不能同時 reveal"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"session":{"info":"h","refresh":5},\#(cmds)}"#, .badHook("session.refresh", "最少 10 秒"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"tick":{"action":"h","every":10},\#(cmds)}"#, .badHook("tick.every", "最少 30 秒"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"tick":{},\#(cmds)}"#, .missingField("tick.action"))
}

@Test func invocationSubstitutesAndFeedsStdin() throws {
    let t = try parse(sample)
    let status = try t.invocation(action: "status", args: [])
    #expect(status == .init(executable: "/Users/me/.t/bin/cli", arguments: ["status", "--json"], stdin: nil, reveal: false, directory: "/plugins/t"))
    let set = try t.invocation(action: "config.set", args: ["notify.sound", "on"])
    #expect(set.arguments == ["config", "set", "notify.sound", "on"])
    let write = try t.invocation(action: "asset.write", args: ["skills", "my-skill", "# 中文內容\n"])
    #expect(write.arguments == ["edit", "write", "skills", "my-skill"] && write.stdin == "# 中文內容\n")
    let reveal = try t.invocation(action: "asset.reveal", args: ["skills", "x"])
    #expect(reveal.reveal)
}

@Test func invocationRejectsWhatTheWhitelistWouldHave() throws {
    let t = try parse(sample)
    #expect(throws: ToolPlugin.InvokeError.unknownAction("rm")) { try t.invocation(action: "rm", args: []) }
    #expect(throws: ToolPlugin.InvokeError.argumentCount(expected: 1, got: 0)) { try t.invocation(action: "skill.on", args: []) }
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 1, reason: "名稱只能有英數、.、_、-")) { try t.invocation(action: "skill.on", args: ["../x"]) }
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 1, reason: "名稱只能有英數、.、_、-")) { try t.invocation(action: "skill.on", args: ["技能"]) }
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 1, reason: "名稱不能是 . 或 ..")) { try t.invocation(action: "skill.on", args: [".."]) }
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 1, reason: "名稱不能是 . 或 ..")) { try t.invocation(action: "skill.on", args: ["."]) }
    #expect(try t.invocation(action: "skill.on", args: [".hidden"]).arguments.last == ".hidden")
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 2, reason: "值不能以 - 開頭")) { try t.invocation(action: "config.set", args: ["k", "--force"]) }
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 2, reason: "值不能有控制字元")) { try t.invocation(action: "config.set", args: ["k", "a\nb"]) }
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 1, reason: "要是 skills、rules 之一")) { try t.invocation(action: "asset.write", args: ["agents", "n", "x"]) }
    let big = String(repeating: "x", count: ToolPlugin.textLimit + 1)
    #expect(throws: ToolPlugin.InvokeError.badArgument(index: 3, reason: "內容超過 256 KB")) { try t.invocation(action: "asset.write", args: ["skills", "n", big]) }
    #expect(try t.invocation(action: "config.set", args: ["k", "繁中值 OK"]).arguments.last == "繁中值 OK")
}

/// The sample plugin the docs point at stays loadable.
@Test func exampleToolManifestLoads() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = repo.appendingPathComponent("docs/plugins/example-tool")
    let tool = try ToolPlugin.load(url: dir.appendingPathComponent("manifest.json"), home: home)
    #expect(tool.id == "example-tool" && tool.panel.bridge == "cubi")
    #expect(tool.panel.file == dir.appendingPathComponent("index.html").path)
    #expect(FileManager.default.fileExists(atPath: tool.panel.file))
    #expect(try tool.invocation(action: "hello", args: ["世界"]).arguments == ["hello,", "世界"])
    #expect(try tool.invocation(action: "date", args: []).executable == "/bin/date")
    #expect(throws: ToolPlugin.InvokeError.self) { try tool.invocation(action: "hello", args: ["-n"]) }
    #expect(tool.session == .init(info: "session.info", refresh: 60))
    // What the sample echoes is a valid widget: one plain row, one link row.
    let echoed = try tool.invocation(action: "session.info", args: ["{}"]).arguments[0]
    let widget = try PluginIO.WidgetOutput.parse(echoed, tool: tool)
    #expect(widget.rows.count == 2 && widget.rows[1].url == "https://github.com/jc33654/cubi")
}
