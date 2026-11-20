import Testing
import Foundation
@testable import CubiKit

// Inputs: the repo's three manifests (docs/plugins/*), each changed in one field. Every changed
// value is a constant from the code (supportedSchema, timeoutRange, the parsers' key lists), a
// value derived from one, 1e300 (the value ToolPlugin.seconds names as trapping Int(Double)), or
// an observation from the batch-49 audit ("x" schema and kind "Tool" both loaded before).

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let home = "/Users/me"

private func manifest(_ folder: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: repo.appendingPathComponent("docs/plugins/\(folder)/manifest.json")))
}

private func with(_ v: JSONValue, _ key: String, _ new: JSONValue?) -> JSONValue {
    var o = v.object!
    o[key] = new
    return .object(o)
}

private func check(_ m: JSONValue, folder: String) throws -> PluginManifest.Loaded {
    try PluginManifest.check(m, folder: folder, baseDirectory: repo.appendingPathComponent("docs/plugins/\(folder)").path, home: home)
}

@Test func repoManifestsLoadWithoutWarnings() throws {
    for folder in ["example-tool", "example-agent", "sprint"] {
        let loaded = try check(try manifest(folder), folder: folder)
        #expect(loaded.plugin.id == folder)
        #expect(loaded.warnings == [], "\(folder)")
    }
}

// M1
@Test func schemaIsOneWhenAbsentAndRefusedWhenNewerOrNotAWholeNumber() throws {
    let tool = try manifest("example-tool")
    #expect(try check(with(tool, "schema", nil), folder: "example-tool").plugin.id == "example-tool")
    #expect(try check(with(tool, "schema", .number(Double(PluginManifest.supportedSchema))), folder: "example-tool").plugin.id == "example-tool")
    let newer = PluginManifest.supportedSchema + 1
    #expect(throws: PluginManifest.LoadError.newerSchema(newer)) { try check(with(tool, "schema", .number(Double(newer))), folder: "example-tool") }
    #expect(PluginManifest.LoadError.newerSchema(newer).errorDescription?.contains("請更新 Cubi") == true)
    for bad: JSONValue in [.string("x"), .number(Double(PluginManifest.supportedSchema) + 0.5), .number(0), .number(1e300), .bool(true), .null] {
        #expect(throws: PluginManifest.LoadError.badSchema, "\(bad)") { try check(with(tool, "schema", bad), folder: "example-tool") }
    }
}

// M2: kind
@Test func kindIsToolAgentOrAbsent() throws {
    let tool = try manifest("example-tool"), agent = try manifest("example-agent")
    guard case .agent = try check(agent, folder: "example-agent").plugin else { Issue.record("no kind is agent"); return }
    guard case .agent = try check(with(agent, "kind", .string("agent")), folder: "example-agent").plugin else { Issue.record("agent"); return }
    guard case .tool = try check(tool, folder: "example-tool").plugin else { Issue.record("tool"); return }
    #expect(throws: PluginManifest.LoadError.badKind("「Tool」")) { try check(with(tool, "kind", .string("Tool")), folder: "example-tool") }
    #expect(throws: PluginManifest.LoadError.badKind("null")) { try check(with(tool, "kind", .null), folder: "example-tool") }
}

// M2: folder name
@Test func folderNameMustBeTheID() throws {
    #expect(throws: PluginManifest.LoadError.folderMismatch(folder: "example-agent", id: "example-tool")) {
        try check(try manifest("example-tool"), folder: "example-agent")
    }
}

// M2: unknown keys
@Test func unknownKeysWarnButLoadAndXKeysAreTheAuthors() throws {
    let tool = try manifest("example-tool")
    // An agent-only key in a tool manifest, and keys spelt in the wrong case.
    var panel = tool["panel"]!.object!
    panel["File"] = panel["file"]
    var commands = tool["commands"]!.object!
    var hello = commands["hello"]!.object!
    hello["sessionAllowed".lowercased()] = .bool(true)
    commands["hello"] = .object(hello)
    var m = with(with(tool, "color", .string("#2DD4BF")), "panel", .object(panel))
    m = with(m, "commands", .object(commands))
    let loaded = try check(m, folder: "example-tool")
    #expect(loaded.warnings == [
        "不認得的欄位 color（拼錯了嗎？自己用的欄位請以 x- 開頭）",
        "不認得的欄位 commands.hello.sessionallowed（拼錯了嗎？自己用的欄位請以 x- 開頭）",
        "不認得的欄位 panel.File（拼錯了嗎？自己用的欄位請以 x- 開頭）",
    ])
    // The typo is not read as the real key.
    guard case .tool(let t) = loaded.plugin else { Issue.record("tool"); return }
    #expect(t.commands["hello"]?.sessionAllowed == false)
    // The same keys under x- are the author's: no warning, anywhere.
    hello["x-sessionallowed"] = hello.removeValue(forKey: "sessionallowed")
    commands["hello"] = .object(hello)
    var quiet = with(with(tool, "x-color", .string("#2DD4BF")), "commands", .object(commands))
    quiet = with(quiet, "x-" + "panel", tool["panel"])
    #expect(try check(quiet, folder: "example-tool").warnings == [])
}

@Test func unknownKeysInsideAgentArraysAndMapsAreNamed() throws {
    let agent = try manifest("example-agent")
    var install = agent["install"]!.object!
    var entries = install["entries"]!.array!
    var first = entries[0].object!
    first["Timeout"] = first["timeout"]
    entries[0] = .object(first)
    install["entries"] = .array(entries)
    var events = agent["events"]!.object!
    var start = events["SessionStart"]!.object!
    var map = start["map"]!.object!
    map["sessionID"] = map["session"]
    start["map"] = .object(map)
    events["SessionStart"] = .object(start)
    let loaded = try check(with(with(agent, "install", .object(install)), "events", .object(events)), folder: "example-agent")
    #expect(loaded.warnings == [
        "不認得的欄位 events.SessionStart.map.sessionID（拼錯了嗎？自己用的欄位請以 x- 開頭）",
        "不認得的欄位 install.entries[0].Timeout（拼錯了嗎？自己用的欄位請以 x- 開頭）",
    ])
}

// M3
@Test func agentTimeoutIsAWholeNumberOfSecondsInRangeAndNeverACrash() throws {
    let agent = try manifest("example-agent")
    func withTimeout(_ t: JSONValue) -> JSONValue {
        var install = agent["install"]!.object!
        var entries = install["entries"]!.array!
        var first = entries[0].object!
        first["timeout"] = t
        entries[0] = .object(first)
        install["entries"] = .array(entries)
        return with(agent, "install", .object(install))
    }
    let range = ManifestPlugin.timeoutRange
    let refusal = ManifestPlugin.LoadError.badField("install.entries[0].timeout", "要是 \(range.lowerBound)–\(range.upperBound) 的整數秒")
    for bad: JSONValue in [.number(1e300), .number(-1e300), .number(.nan), .number(.infinity), .number(Double(range.lowerBound - 1)),
                           .number(-Double(range.upperBound)), .number(Double(range.upperBound + 1)), .number(Double(range.lowerBound) + 0.5), .string("10")] {
        #expect(throws: refusal, "\(bad)") { try ManifestPlugin.parse(withTimeout(bad)) }
    }
    #expect(refusal.errorDescription == "install.entries[0].timeout：要是 1–600 的整數秒")
    for ok in [range.lowerBound, range.upperBound] {
        #expect(try ManifestPlugin.parse(withTimeout(.number(Double(ok)))).installEntries[0].timeout == ok)
    }
    // Not given: 10, as before.
    var install = agent["install"]!.object!
    var entries = install["entries"]!.array!
    var first = entries[0].object!
    first.removeValue(forKey: "timeout")
    entries[0] = .object(first)
    install["entries"] = .array(entries)
    #expect(try ManifestPlugin.parse(with(agent, "install", .object(install))).installEntries[0].timeout == 10)
}

// M4
@Test func agentErrorsAreChineseAndNameTheField() throws {
    let agent = try manifest("example-agent")
    let cases: [(JSONValue, String)] = [
        (with(agent, "name", nil), "缺少欄位 name"),
        (with(agent, "id", .string("Example_Agent")), "id「Example_Agent」不合法（小寫英數與 -，最多 24 字）"),
        (with(agent, "install", .object(["mode": .string("json_hooks")])), "install.mode：只能是 json-hooks 或 manual"),
        (with(agent, "install", .object(["mode": .string("json-hooks")])), "缺少欄位 install.file"),
        (with(agent, "events", .object(["AgentDone": .object(["canonical": .string("done")])])),
         "events.AgentDone.canonical：必填，要是 \(ManifestPlugin.canonicalEvents.joined(separator: "、")) 之一"),
        (with(agent, "events", .object(["AgentDone": .object(["map": .object([:])])])),
         "events.AgentDone.canonical：必填，要是 \(ManifestPlugin.canonicalEvents.joined(separator: "、")) 之一"),
    ]
    for (m, message) in cases {
        do {
            _ = try ManifestPlugin.parse(m)
            Issue.record("loaded: \(message)")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription == message)
        }
    }
}

// M5
@Test func actionNamesAreLowerCaseLettersDigitsAndDotUnderscoreDash() throws {
    let tool = try manifest("example-tool")
    var commands = tool["commands"]!.object!
    commands["HELLO"] = commands.removeValue(forKey: "hello")
    #expect(throws: ToolPlugin.LoadError.badCommand("HELLO", "動作名稱只能有小寫英數與 . _ -、第一個字要是英數，1–64 字")) {
        try check(with(tool, "commands", .object(commands)), folder: "example-tool")
    }
    // Every action the repo's plugins use passes.
    for folder in ["example-tool", "sprint"] {
        for action in try manifest(folder)["commands"]!.object!.keys { #expect(ToolPlugin.isValidActionName(action), "\(action)") }
    }
    #expect(!ToolPlugin.isValidActionName(""))
    #expect(!ToolPlugin.isValidActionName(String(repeating: "a", count: 65)))
    #expect(ToolPlugin.isValidActionName(String(repeating: "a", count: 64)))
}

@Test func plainPathTellsTheInstallLocationFromTheAction() {
    // The docs' install path (advanced.md, 命令列) with ~ expanded, and the same with a space.
    let path = "/Users/me/Applications/Cubi.app/Contents/MacOS/cubi"
    #expect(SessionLaunch.isPlainPath(path))
    #expect(!SessionLaunch.isPlainPath(path.replacingOccurrences(of: "Applications", with: "My Apps")))
    #expect(!SessionLaunch.isPlainPath("Applications/Cubi.app/Contents/MacOS/cubi"))
}

// M6
@Test func validateReportsLoadDiskAndWarnings() throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cubi-validate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let folder = scratch.appendingPathComponent("example-tool")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repo.appendingPathComponent("docs/plugins/example-tool"), to: folder)
    let manifestURL = folder.appendingPathComponent("manifest.json")
    func write(_ v: JSONValue) throws { try JSONEncoder().encode(v).write(to: manifestURL) }
    let original = try manifest("example-tool")

    let good = PluginManifest.validate(directory: folder, home: home)
    #expect(good.errors == [] && good.warnings == [])
    #expect(good.summary == "工具套件 example-tool：3 個指令、session hook")

    // hello pointed at the panel's own HTML (there, not executable) and date at a file that is not there.
    var commands = original["commands"]!.object!
    commands["hello"] = .object(["run": .array([.string("$plugin/index.html"), .string("$1")]), "args": .array([.string("value")])])
    commands["date"] = .object(["run": .array([.string("$plugin/date")])])
    try write(with(with(original, "commands", .object(commands)), "color", .string("#2DD4BF")))
    let bad = PluginManifest.validate(directory: folder, home: home)
    #expect(bad.errors == [
        "commands.date：找不到執行檔 \(folder.path)/date",
        "commands.hello：\(folder.path)/index.html 不能執行（chmod +x，或第一格寫 /usr/bin/python3、腳本放第二格）",
    ])
    #expect(bad.warnings == ["不認得的欄位 color（拼錯了嗎？自己用的欄位請以 x- 開頭）"])

    // A manifest that does not load at all: its one error, nothing else.
    try write(with(original, "schema", .number(Double(PluginManifest.supportedSchema + 1))))
    let refused = PluginManifest.validate(directory: folder, home: home)
    #expect(refused.errors == [PluginManifest.LoadError.newerSchema(PluginManifest.supportedSchema + 1).errorDescription!])
    #expect(refused.summary == nil)

    // The panel file gone.
    try write(original)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("index.html"))
    #expect(PluginManifest.validate(directory: folder, home: home).errors == ["panel.file：找不到 \(folder.path)/index.html"])

    // No manifest at all.
    #expect(PluginManifest.validate(directory: scratch.appendingPathComponent("sprint"), home: home).errors.first?.hasPrefix("讀不到 manifest.json") == true)
}
