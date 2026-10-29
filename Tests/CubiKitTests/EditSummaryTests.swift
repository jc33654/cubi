import Testing
@testable import CubiKit

@Test func structuredPatchIsPreferred() {
    let input: JSONValue = .object(["file_path": .string("/a/b/c.swift"), "old_string": .string("x"), "new_string": .string("y")])
    let response: JSONValue = .object(["structuredPatch": .array([.object([
        "oldStart": .number(10), "newStart": .number(10),
        "lines": .array([.string(" keep"), .string("-old"), .string("+new1"), .string("+new2")]),
    ])])])
    let s = EditSummaryBuilder.build(tool: "Edit", input: input, response: response)!
    #expect(s.fileName == "c.swift")
    #expect(s.added == 2 && s.removed == 1)
    #expect(s.lines.first?.kind == .hunk)
    #expect(s.lines.map(\.kind) == [.hunk, .context, .removed, .added, .added])
    #expect(s.label == "c.swift +2 −1")
}

@Test func editFallsBackToLineDiff() {
    let input: JSONValue = .object(["file_path": .string("f.txt"), "old_string": .string("a\nb\nc"), "new_string": .string("a\nB\nc\nd")])
    let s = EditSummaryBuilder.build(tool: "Edit", input: input, response: .null)!
    #expect(s.added == 2 && s.removed == 1)
    #expect(s.lines.map(\.kind) == [.context, .removed, .added, .context, .added])
}

@Test func writeWithoutOriginalIsAllAdded() {
    let input: JSONValue = .object(["file_path": .string("new.txt"), "content": .string("one\ntwo")])
    let s = EditSummaryBuilder.build(tool: "Write", input: input, response: .object(["type": .string("create")]))!
    #expect(s.added == 2 && s.removed == 0)
}

@Test func nonEditingToolIsNil() {
    #expect(EditSummaryBuilder.build(tool: "Bash", input: .null, response: .null) == nil)
    #expect(EditSummaryBuilder.build(tool: "Edit", input: .object([:]), response: .null) == nil)
}

@Test func lineDiffHandlesEmptyAndIdentical() {
    #expect(EditSummaryBuilder.lineDiff([], ["a"]).map(\.kind) == [.added])
    #expect(EditSummaryBuilder.lineDiff(["a"], []).map(\.kind) == [.removed])
    #expect(EditSummaryBuilder.lineDiff(["a", "b"], ["a", "b"]).allSatisfy { $0.kind == .context })
}
