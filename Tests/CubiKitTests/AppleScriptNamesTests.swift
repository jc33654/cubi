import Foundation
import Testing

/// The terminal scripts' own variables must be free names: one that is a scripting term compiles
/// and then fails at run time (`set titled to -1`: -10006), which broke every robot click in
/// build 165. Each `set X to` in the scripts' source is run on its own, outside any `tell`.
@Test func terminalScriptVariablesAreFreeNames() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pattern = try NSRegularExpression(pattern: #"\bset ([A-Za-z][A-Za-z0-9]*) to\b"#)
    var names = Set<String>()
    for file in ["Sources/cubi/TerminalFocus.swift", "Sources/cubi/SessionLauncher.swift"] {
        let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            names.insert(String(text[Range(match.range(at: 1), in: text)!]))
        }
    }
    #expect(names.isSuperset(of: ["hitsTitle", "hitsNarrow", "hitsCwd", "matchedBy", "target"]))
    #expect(!names.contains("titled"))
    for name in names.sorted() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "set \(name) to -1"]
        let err = Pipe()
        process.standardOutput = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "set \(name) to -1: \(message)")
    }
}
