import Testing
import Foundation
@testable import CubiKit

// Inputs: docs/plugins/example-tool/manifest.json with a `service` added. Its argv words come from
// that manifest: `date`'s run (/bin/date), `hello`'s run (/bin/echo, $1), the command name `date`,
// the panel file (index.html). Every other value is a constant from the code (Restart and
// ServiceEvent cases, the `~` the loader accepts, the keys of a command, ToolPlugin.seconds'
// default, the home these tests share) or one derived from it.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let folder = "example-tool"
private let base = repo.appendingPathComponent("docs/plugins/\(folder)").path
private let home = "/Users/me"
private let notice = JSONValue.string(ToolPlugin.ServiceEvent.notice.rawValue)
private let date: [JSONValue] = [.string("/bin/date")]

private func example(service: JSONValue?) throws -> JSONValue {
    var m = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: base + "/manifest.json"))).object!
    m["service"] = service
    return .object(m)
}

/// `{"run": run, "events": events}` plus `extra`; nil leaves a key out.
private func service(run: [JSONValue]?, events: [JSONValue]?, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    var o = extra
    if let run { o["run"] = .array(run) }
    if let events { o["events"] = .array(events) }
    return .object(o)
}

private func load(_ m: JSONValue) throws -> PluginManifest.Loaded {
    try PluginManifest.check(m, folder: folder, baseDirectory: base, home: home)
}

private func tool(_ m: JSONValue) throws -> ToolPlugin {
    guard case .tool(let t) = try load(m).plugin else { throw ToolPlugin.LoadError.missingField("kind") }
    return t
}

@Test func aServiceLoadsWithItsDefaultsAndRunsItsOwnArgv() throws {
    let loaded = try load(try example(service: service(run: date, events: [notice])))
    #expect(loaded.warnings == [])
    guard case .tool(let t) = loaded.plugin else { Issue.record("not a tool"); return }
    #expect(t.service == ToolPlugin.Service(run: ["/bin/date"], restart: .onFailure, events: [.notice]))
    #expect(t.serviceInvocation == ToolPlugin.Invocation(executable: "/bin/date", arguments: [], stdin: nil, reveal: false, directory: base))
    // Without a service nothing changes.
    let plain = try tool(try example(service: nil))
    #expect(plain.service == nil)
    #expect(plain.serviceInvocation == nil)
}

@Test func everyRestartAndEventNameIsTakenAndNothingElse() throws {
    for r in ToolPlugin.Restart.allCases {
        let t = try tool(try example(service: service(run: date, events: [notice], ["restart": .string(r.rawValue)])))
        #expect(t.service?.restart == r)
    }
    let all = ToolPlugin.ServiceEvent.allCases
    let t = try tool(try example(service: service(run: date, events: all.map { .string($0.rawValue) })))
    #expect(t.service?.events == Set(all))

    let upper = ToolPlugin.Restart.never.rawValue.uppercased()
    #expect(throws: ToolPlugin.LoadError.badField("service.restart", "只能是 on-failure、never")) {
        try tool(try example(service: service(run: date, events: [notice], ["restart": .string(upper)])))
    }
    // A key of the manifest that is not an event name.
    #expect(throws: ToolPlugin.LoadError.badField("service.events[1]", "只能是 notice、present、state、log、reply")) {
        try tool(try example(service: service(run: date, events: [notice, .string("tick")])))
    }
    #expect(throws: ToolPlugin.LoadError.badField("service.events[1]", "「notice」重複了")) {
        try tool(try example(service: service(run: date, events: [notice, notice])))
    }
    #expect(throws: ToolPlugin.LoadError.badField("service.events", "至少要列一種")) {
        try tool(try example(service: service(run: date, events: [])))
    }
    #expect(throws: ToolPlugin.LoadError.missingField("service.events")) {
        try tool(try example(service: service(run: date, events: nil)))
    }
    #expect(throws: ToolPlugin.LoadError.missingField("service.run")) {
        try tool(try example(service: service(run: nil, events: [notice])))
    }
    #expect(throws: ToolPlugin.LoadError.badField("service", "要是物件")) {
        try tool(try example(service: .string("/bin/date")))
    }
}

@Test func theServiceArgvFollowsTheCommandRulesAndTakesNoArguments() throws {
    func run(_ words: [JSONValue]) throws -> [String]? {
        try tool(try example(service: service(run: words, events: [notice]))).service?.run
    }
    // $plugin, ~ and plain words resolve as in a command.
    #expect(try run([.string("$plugin/index.html")]) == [base + "/index.html"])
    #expect(try run([.string("/bin/echo"), .string("$plugin")]) == ["/bin/echo", base])
    #expect(try run([.string("~")]) == [home])

    let notArgv = ToolPlugin.LoadError.badField("service.run", "要是非空的字串陣列")
    #expect(throws: notArgv) { try run([]) }
    #expect(throws: notArgv) { try run([.string("")]) }
    // An entry that is not a string is refused, not dropped (60 is ToolPlugin.seconds' default).
    #expect(throws: notArgv) { try run(date + [.number(60)]) }
    #expect(throws: notArgv) { try tool(try example(service: .object(["run": .string("/bin/date"), "events": .array([notice])]))) }
    // A command name is not a path: nothing is looked up, in `commands` or on PATH.
    #expect(throws: ToolPlugin.LoadError.badField("service.run", "執行檔要是路徑（絕對、~ 或相對插件目錄，不能只寫名字）")) {
        try run([.string("date")])
    }
    // `hello`'s argv: the service has no arguments to put in $1.
    #expect(throws: ToolPlugin.LoadError.badField("service.run", "不能用 $1：背景服務沒有參數（stdin 是 Cubi 跟它溝通用的）")) {
        try run([.string("/bin/echo"), .string("$1")])
    }

    // The service is not a command: every command still runs as before, and no command is added.
    let t = try tool(try example(service: service(run: date, events: [notice])))
    #expect(try t.invocation(action: "date", args: []).executable == "/bin/date")
    #expect(Set(t.commands.keys) == ["hello", "date", "session.info"])
    #expect(t.sessionActions.isEmpty)
    // A command's own flags are not keys of `service`.
    for flag in ["reveal", "sessionAllowed"] {
        let m = try example(service: service(run: date, events: [notice], [flag: .bool(true)]))
        #expect(try load(m).warnings == ["不認得的欄位 service.\(flag)（拼錯了嗎？自己用的欄位請以 x- 開頭）"])
    }
}

@Test func unknownKeysInsideServiceAreNamedAndXKeysAreTheAuthors() throws {
    // `every` is a key of `tick`, not of `service`; 60 is its default (ToolPlugin.seconds).
    let m = try example(service: service(run: date, events: [notice], ["every": .number(60), "x-note": .string(folder)]))
    #expect(try load(m).warnings == ["不認得的欄位 service.every（拼錯了嗎？自己用的欄位請以 x- 開頭）"])
}

@Test func validateChecksTheServiceExecutableOnDisk() throws {
    func problems(_ words: [JSONValue]) throws -> [String] {
        PluginManifest.fileProblems(try tool(try example(service: service(run: words, events: [notice]))))
    }
    #expect(try problems(date) == [])
    // The panel file exists but is not executable. Missing: the same file under bin/, where the plan puts the helper (plugins/lan-nudge/bin/).
    #expect(try problems([.string("$plugin/index.html")]) == ["service.run：\(base)/index.html 不能執行（chmod +x，或第一格寫 /usr/bin/python3、腳本放第二格）"])
    #expect(try problems([.string("$plugin/bin/index.html")]) == ["service.run：找不到執行檔 \(base)/bin/index.html"])
}
