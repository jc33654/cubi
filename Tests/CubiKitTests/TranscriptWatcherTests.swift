import Foundation
import Testing
@testable import CubiKit

private func tempTranscript() -> String {
    let path = NSTemporaryDirectory() + "cubi-watch-\(UUID().uuidString).jsonl"
    FileManager.default.createFile(atPath: path, contents: Data("{\"type\":\"assistant\"}\n".utf8))
    return path
}

private func append(_ path: String, _ line: String) {
    let h = FileHandle(forWritingAtPath: path)!
    h.seekToEndOfFile()
    h.write(Data((line + "\n").utf8))
    try? h.close()
}

@Test func unrelatedUserEntryDoesNotSettle() {
    let path = tempTranscript()
    var w = TranscriptWatcher(path: path)!
    append(path, "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_OLD\"}]}}")
    #expect(w.settled(toolUseID: "toolu_NEW") == false)
}

@Test func matchingToolResultSettles() {
    let path = tempTranscript()
    var w = TranscriptWatcher(path: path)!
    append(path, "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_NEW\",\"content\":\"ok\"}]}}")
    #expect(w.settled(toolUseID: "toolu_NEW") == true)
}

@Test func interruptionSettlesEvenWithoutId() {
    let path = tempTranscript()
    var w = TranscriptWatcher(path: path)!
    append(path, "{\"type\":\"user\",\"message\":{\"content\":\"[Request interrupted by user for tool use]\"}}")
    #expect(w.settled(toolUseID: nil) == true)
}

@Test func noGrowthNoSettlement() {
    let path = tempTranscript()
    var w = TranscriptWatcher(path: path)!
    #expect(w.settled(toolUseID: "x") == false)
    #expect(TranscriptWatcher(path: "/nonexistent/file.jsonl") == nil)
}

@Test func storeRemembersLastToolUseID() throws {
    var store = SessionStore()
    let pre = try Fixtures.decoded("PreToolUse-2")
    #expect(pre.toolUseID?.hasPrefix("toolu_") == true)
    _ = store.apply(pre, now: 1)
    #expect(store.sessions[pre.session.id]?.lastToolUseID == pre.toolUseID)
    let perm = try Fixtures.decoded("PermissionRequest-1")
    #expect(perm.toolUseID == nil)
}
