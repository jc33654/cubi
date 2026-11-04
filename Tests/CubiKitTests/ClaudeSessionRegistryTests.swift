import Testing
import Foundation
@testable import CubiKit

/// A throwaway ~/.claude/sessions with the given files, removed after `body`.
private func withRegistry<T>(_ files: [String: String], _ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cubi-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, body) in files { try Data(body.utf8).write(to: dir.appendingPathComponent(name)) }
    return try body(dir)
}

@Test func registryReadsTheNamePerSession() throws {
    try withRegistry([
        "101.json": #"{"pid":101,"sessionId":"aaaa-1","cwd":"/Users/me/p","name":"甲專案","nameSource":"user","updatedAt":200}"#,
        "102.json": #"{"pid":102,"sessionId":"bbbb-2","cwd":"/Users/me/q","name":"reviewer","updatedAt":100}"#,
        "103.json": #"{"pid":103,"sessionId":"no-name","cwd":"/x","name":"","updatedAt":1}"#,
        "junk.json": #"{"hello":"world"}"#,
        "101.abc.key": "not json",
    ]) { dir in
        #expect(ClaudeSessionRegistry.entries(in: dir).count == 3)
        #expect(ClaudeSessionRegistry.entry(for: "aaaa-1", in: dir) == .init(sessionID: "aaaa-1", name: "甲專案", source: "user", updatedAt: 200))
        #expect(ClaudeSessionRegistry.entry(for: "aaaa-1", in: dir)?.userName == "甲專案")
        // No nameSource (older Claude Code) or "derived": the name is there but not the user's.
        #expect(ClaudeSessionRegistry.entry(for: "bbbb-2", in: dir)?.userName == nil)
        #expect(ClaudeSessionRegistry.entry(for: "no-name", in: dir)?.name == nil)   // empty name is no name
        #expect(ClaudeSessionRegistry.entry(for: "missing", in: dir) == nil)
    }
}

@Test func registryPrefersTheNewestEntryForAResumedSession() throws {
    try withRegistry([
        "1.json": #"{"pid":1,"sessionId":"s","name":"舊名字","updatedAt":100}"#,
        "2.json": #"{"pid":2,"sessionId":"s","name":"新名字","updatedAt":200}"#,
    ]) { dir in
        #expect(ClaudeSessionRegistry.entry(for: "s", in: dir)?.name == "新名字")
    }
}

@Test func registryDerivedNameIsNotAUserName() throws {
    try withRegistry(["1.json": #"{"pid":1,"sessionId":"s","cwd":"/Users/me/proj","name":"proj-32","nameSource":"derived","updatedAt":1}"#]) { dir in
        let e = ClaudeSessionRegistry.entry(for: "s", in: dir)
        #expect(e?.name == "proj-32" && e?.source == "derived" && e?.userName == nil)
    }
}

@Test func registryIgnoresABrokenPidAndAMissingDirectory() throws {
    try withRegistry(["1.json": #"{"pid":1e300,"sessionId":"s","name":"n","updatedAt":1}"#]) { dir in
        #expect(ClaudeSessionRegistry.entry(for: "s", in: dir)?.name == "n")
    }
    #expect(ClaudeSessionRegistry.entries(in: URL(fileURLWithPath: "/nonexistent/cubi-registry")).isEmpty)
}

@Test func storeTakesARegistryNameAsExplicit() {
    var store = SessionStore()
    _ = store.apply(DecodedHook(session: SessionRef(id: "s", cwd: "/Users/me/proj", client: HookClient()),
                                event: .sessionStart(source: "startup")), now: 0)
    #expect(store.sessions["s"]?.name == "proj" && store.sessions["s"]?.explicitName == false)
    store.setName("甲專案", for: "s")
    #expect(store.sessions["s"]?.name == "甲專案" && store.sessions["s"]?.explicitName == true)
    store.setName("", for: "s")
    #expect(store.sessions["s"]?.name == "甲專案")
}
