import Testing
@testable import CubiKit

/// Real Edit/Write PostToolUse payloads recorded from Claude Code 2.1.312 (headless probe).
@Test func recordedEditProducesStructuredDiff() throws {
    let d = try Fixtures.decoded("PostToolUse-7")
    guard case .toolEnd(let tool, let ok, let input, let response) = d.event else { Issue.record("x"); return }
    #expect(tool == "Edit" && ok)
    let s = try #require(EditSummaryBuilder.build(tool: tool, input: input, response: response))
    #expect(s.fileName == "diff-probe.txt")
    #expect(s.added == 1 && s.removed == 1)
    #expect(s.lines.map(\.kind) == [.hunk, .context, .removed, .added, .context])
    #expect(s.lines[3].text == "beta CHANGED")
}

@Test func recordedWriteOfNewFileIsAllAdded() throws {
    let d = try Fixtures.decoded("PostToolUse-6")
    guard case .toolEnd(let tool, _, let input, let response) = d.event else { Issue.record("x"); return }
    #expect(tool == "Write")
    let s = try #require(EditSummaryBuilder.build(tool: tool, input: input, response: response))
    #expect(s.added == 3 && s.removed == 0)
    #expect(s.lines.map(\.text) == ["alpha", "beta", "gamma"])
}

@Test func storeKeepsLastEditAndLabelsTicker() throws {
    var store = SessionStore()
    _ = store.apply(try Fixtures.decoded("PostToolUse-7"), now: 1)
    let s = try #require(store.sessions.values.first)
    #expect(s.lastEdit?.label == "diff-probe.txt +1 −1")
    #expect(s.ticker == "diff-probe.txt +1 −1")
}
