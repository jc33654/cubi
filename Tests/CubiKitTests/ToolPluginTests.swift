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
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["cli","a"]}}}"#, .badCommand("x", "執行檔要是絕對路徑（可用 ~）"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c","$3"],"args":["name"]}}}"#, .badCommand("x", "$3 沒有對應的 args"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c","$1"],"args":["text"]}}}"#, .badCommand("x", "args[0] 是 text，只能經 stdin 傳"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c"],"args":["name"],"stdin":2}}}"#, .badCommand("x", "stdin 要在 1…1"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c","$1"],"args":["text"],"stdin":1}}}"#, .badCommand("x", "$1 已經指定走 stdin"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"x":{"run":["/c"],"args":["path"]}}}"#, .badCommand("x", "args[0] 不認得的型別「path」"))
    fails(#"{"id":"t","name":"T","panel":{"file":"a"},"commands":{"pick.file":{"run":["/c"]}}}"#, .badCommand("pick.file", "保留給面板內建的選擇器，不能自己定義"))
}

@Test func invocationSubstitutesAndFeedsStdin() throws {
    let t = try parse(sample)
    let status = try t.invocation(action: "status", args: [])
    #expect(status == .init(executable: "/Users/me/.t/bin/cli", arguments: ["status", "--json"], stdin: nil, reveal: false))
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
}
