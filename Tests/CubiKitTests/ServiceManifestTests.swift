import Testing
import Foundation
@testable import CubiKit

// Inputs: docs/plugins/example-tool/manifest.json with a `service` added. Its three commands are
// the cases: `date` (no args), `hello` (an argument), `session.info` (stdin). Every other value is a
// constant from the code (Restart and ServiceEvent cases, reservedActions, PluginManifest.toolKeys,
// ToolPlugin.seconds' default) or one derived from it.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let folder = "example-tool"
private let base = repo.appendingPathComponent("docs/plugins/\(folder)").path
private let notice = JSONValue.string(ToolPlugin.ServiceEvent.notice.rawValue)

private func example(service: JSONValue?, commands change: ((inout [String: JSONValue]) -> Void)? = nil) throws -> JSONValue {
    var m = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: base + "/manifest.json"))).object!
    if let change {
        var commands = m["commands"]!.object!
        change(&commands)
        m["commands"] = .object(commands)
    }
    m["service"] = service
    return .object(m)
}

/// `{"run": run, "events": events}` plus `extra`; nil leaves a key out.
private func service(run: String?, events: [JSONValue]?, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    var o = extra
    if let run { o["run"] = .string(run) }
    if let events { o["events"] = .array(events) }
    return .object(o)
}

private func load(_ m: JSONValue) throws -> PluginManifest.Loaded {
    try PluginManifest.check(m, folder: folder, baseDirectory: base, home: "/Users/me")
}

private func tool(_ m: JSONValue) throws -> ToolPlugin {
    guard case .tool(let t) = try load(m).plugin else { throw ToolPlugin.LoadError.missingField("kind") }
    return t
}

@Test func aServiceLoadsWithItsDefaultsAndRunsTheCommandAsDeclared() throws {
    let loaded = try load(try example(service: service(run: "date", events: [notice])))
    #expect(loaded.warnings == [])
    guard case .tool(let t) = loaded.plugin else { Issue.record("not a tool"); return }
    #expect(t.service == ToolPlugin.Service(action: "date", restart: .onFailure, events: [.notice]))
    #expect(t.serviceInvocation == ToolPlugin.Invocation(executable: "/bin/date", arguments: [], stdin: nil, reveal: false, directory: base))
    // Without a service nothing changes.
    let plain = try tool(try example(service: nil))
    #expect(plain.service == nil)
    #expect(plain.serviceInvocation == nil)
}

@Test func everyRestartAndEventNameIsTakenAndNothingElse() throws {
    for r in ToolPlugin.Restart.allCases {
        let t = try tool(try example(service: service(run: "date", events: [notice], ["restart": .string(r.rawValue)])))
        #expect(t.service?.restart == r)
    }
    let all = ToolPlugin.ServiceEvent.allCases
    let t = try tool(try example(service: service(run: "date", events: all.map { .string($0.rawValue) })))
    #expect(t.service?.events == Set(all))

    let upper = ToolPlugin.Restart.never.rawValue.uppercased()
    #expect(throws: ToolPlugin.LoadError.badField("service.restart", "只能是 on-failure、never")) {
        try tool(try example(service: service(run: "date", events: [notice], ["restart": .string(upper)])))
    }
    // A key of the manifest that is not an event name.
    #expect(throws: ToolPlugin.LoadError.badField("service.events[1]", "只能是 notice、present、state、log、reply")) {
        try tool(try example(service: service(run: "date", events: [notice, .string("tick")])))
    }
    #expect(throws: ToolPlugin.LoadError.badField("service.events[1]", "「notice」重複了")) {
        try tool(try example(service: service(run: "date", events: [notice, notice])))
    }
    #expect(throws: ToolPlugin.LoadError.badField("service.events", "至少要列一種")) {
        try tool(try example(service: service(run: "date", events: [])))
    }
    #expect(throws: ToolPlugin.LoadError.missingField("service.events")) {
        try tool(try example(service: service(run: "date", events: nil)))
    }
    #expect(throws: ToolPlugin.LoadError.missingField("service.run")) {
        try tool(try example(service: service(run: nil, events: [notice])))
    }
    #expect(throws: ToolPlugin.LoadError.badField("service", "要是物件")) {
        try tool(try example(service: .string("date")))
    }
}

@Test func theServiceCommandTakesNoInputAndIsNotForPanelsOrSessions() throws {
    // A built-in name is never a declared command.
    let builtin = ToolPlugin.reservedActions.sorted()[0]
    #expect(throws: ToolPlugin.LoadError.badField("service.run", "沒有這個命令「\(builtin)」")) {
        try tool(try example(service: service(run: builtin, events: [notice])))
    }
    for action in ["hello", "session.info"] {
        #expect(throws: ToolPlugin.LoadError.badField("service.run", "「\(action)」不能有 args 或 stdin（stdin 是 Cubi 跟它溝通用的）")) {
            try tool(try example(service: service(run: action, events: [notice])))
        }
    }
    for flag in ["reveal", "sessionAllowed"] {
        let m = try example(service: service(run: "date", events: [notice])) { commands in
            var date = commands["date"]!.object!
            date[flag] = .bool(true)
            commands["date"] = .object(date)
        }
        #expect(throws: ToolPlugin.LoadError.badField("service.run", "「date」不能 reveal 或 sessionAllowed")) { try tool(m) }
    }

    // Loaded, it can only be started by Cubi; the other commands are untouched.
    let t = try tool(try example(service: service(run: "date", events: [notice])))
    #expect(throws: ToolPlugin.InvokeError.serviceOnly("date")) { try t.invocation(action: "date", args: []) }
    #expect(try t.invocation(action: "hello", args: [folder]).arguments == ["hello,", folder])
    #expect(!t.sessionActions.contains("date"))
}

@Test func unknownKeysInsideServiceAreNamedAndXKeysAreTheAuthors() throws {
    // `every` is a key of `tick`, not of `service`; 60 is its default (ToolPlugin.seconds).
    let m = try example(service: service(run: "date", events: [notice], ["every": .number(60), "x-note": .string(folder)]))
    #expect(try load(m).warnings == ["不認得的欄位 service.every（拼錯了嗎？自己用的欄位請以 x- 開頭）"])
}
