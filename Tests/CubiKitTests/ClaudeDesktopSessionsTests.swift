import Testing
import Foundation
@testable import CubiKit

/// A throwaway claude-code-sessions tree with the given files (paths relative to its root), removed after `body`.
private func withDesktopSessions<T>(_ files: [String: String], _ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cubi-desktop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for (path, contents) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    return try body(dir)
}

@Test func desktopSessionsMapACliSessionToTheAppsLocalID() throws {
    try withDesktopSessions([
        "acct/org/local_aaa.json": #"{"sessionId":"local_aaa","cliSessionId":"4fbbced6-1","isArchived":false,"lastFocusedAt":200,"title":"讀 README","promptAppendSnapshot":{"big":[1,2,3]}}"#,
        "acct/org/local_bbb.json": #"{"sessionId":"local_bbb","cliSessionId":"ddea299b-2"}"#,
        "acct/org/local_gone.json": #"{"sessionId":"local_gone","cliSessionId":"archived-3","isArchived":true}"#,
        "acct/org/local_ddd.json": #"{"sessionId":"local_ddd","title":"no cli id yet"}"#,
        "acct/org/scheduled-tasks.json": #"{"tasks":[]}"#,
        "acct/org/waiting-input/local_deeper.json": #"{"sessionId":"local_deeper","cliSessionId":"too-deep-4"}"#,
        "acct/local_shallow.json": #"{"sessionId":"local_shallow","cliSessionId":"too-shallow-5"}"#,
        "acct/org/local_bad.json": "not json",
    ]) { dir in
        let entries = ClaudeDesktopSessions.entries(in: dir)
        #expect(entries.count == 2)
        #expect(ClaudeDesktopSessions.entry(for: "4fbbced6-1", in: entries) == .init(localID: "local_aaa", cliSessionID: "4fbbced6-1", lastFocusedAt: 200))
        #expect(ClaudeDesktopSessions.entry(for: "ddea299b-2", in: entries)?.localID == "local_bbb")
        #expect(ClaudeDesktopSessions.entry(for: "archived-3", in: entries) == nil)   // an archived conversation is not a place to jump to
        #expect(ClaudeDesktopSessions.entry(for: "too-deep-4", in: entries) == nil)
        #expect(ClaudeDesktopSessions.entry(for: "too-shallow-5", in: entries) == nil)
        #expect(ClaudeDesktopSessions.entry(for: "missing", in: entries) == nil)
    }
    #expect(ClaudeDesktopSessions.entries(in: URL(fileURLWithPath: "/nonexistent/cubi-desktop")).isEmpty)
}

@Test func desktopSessionsPreferTheOneLookedAtLastWhenResumedTwice() {
    let entries = [
        ClaudeDesktopSessions.Entry(localID: "local_old", cliSessionID: "s", lastFocusedAt: 100),
        ClaudeDesktopSessions.Entry(localID: "local_new", cliSessionID: "s", lastFocusedAt: 300),
        ClaudeDesktopSessions.Entry(localID: "local_other", cliSessionID: "t", lastFocusedAt: 900),
    ]
    #expect(ClaudeDesktopSessions.entry(for: "s", in: entries)?.localID == "local_new")
}

@Test func desktopContinueLinkCarriesTheLocalID() {
    #expect(ClaudeDesktopSessions.continueLink("local_8e00282b-9c70")?.absoluteString == "claude://code/continue?session=local_8e00282b-9c70")
    #expect(ClaudeDesktopSessions.continueLink("local_bad id&x=1") == nil)
    #expect(ClaudeDesktopSessions.continueLink("session_abc") == nil)
}
