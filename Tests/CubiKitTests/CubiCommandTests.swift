import Testing
import Foundation
@testable import CubiKit

// Inputs: the mode flags main.swift itself checks (read from the file), the argv lines the batch-50
// review ran against the release build, the allow rule SessionLaunch.allowRule writes, and the
// repo's sprint manifest. Nothing here runs cubi.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every flag main.swift treats as a mode: `at("--x")`, `mode == "--x"`, and the hooks list.
private func modesInMain() throws -> Set<String> {
    let source = try String(contentsOf: repo.appendingPathComponent("Sources/cubi/main.swift"), encoding: .utf8)
    var found = Set<String>()
    for pattern in [#"at\("(--[a-z-]+)"\)"#, #"mode == "(--[a-z-]+)""#] {
        let re = try NSRegularExpression(pattern: pattern)
        for m in re.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            found.insert(String(source[Range(m.range(at: 1), in: source)!]))
        }
    }
    let hooksLine = try #require(source.split(separator: "\n").first { $0.contains(".contains(m)") })
    let flag = try NSRegularExpression(pattern: #""(--[a-z-]+)""#)
    for m in flag.matches(in: String(hooksLine), range: NSRange(hooksLine.startIndex..., in: hooksLine)) {
        found.insert(String(hooksLine[Range(m.range(at: 1), in: hooksLine)!]))
    }
    return found
}

@Test func theModeListIsExactlyWhatMainHandles() throws {
    #expect(try modesInMain() == Set(CubiCommand.modes))
    // main.swift no longer looks a mode up anywhere in argv.
    let source = try String(contentsOf: repo.appendingPathComponent("Sources/cubi/main.swift"), encoding: .utf8)
    for m in CubiCommand.modes {
        #expect(!source.contains(#"firstIndex(of: "\#(m)")"#) && !source.contains(#"arguments.contains("\#(m)")"#), "\(m)")
    }
}

@Test func theModeIsTheFirstArgumentOnly() {
    for m in CubiCommand.modes {
        #expect(CubiCommand.mode(["cubi", m]) == m)
        #expect(CubiCommand.mode(["cubi", "x", m]) == nil, "\(m)")
    }
    #expect(CubiCommand.mode(["cubi"]) == nil)
    #expect(CubiCommand.mode(["cubi", "--settings"]) == nil)   // the app's own flag: the app starts
}

/// The review's two runs: before the fix, the flag after the action took over.
@Test func aFlagAfterToolRunIsAnArgumentNotAMode() throws {
    let version = ["cubi", "--tool-run", "sprint", "estimate.suggest", "--version"]
    #expect(CubiCommand.mode(version) == "--tool-run")
    #expect(CubiCommand.toolRun(version) == .init(id: "sprint", action: "estimate.suggest", args: ["--version"]))
    let validate = ["cubi", "--tool-run", "sprint", "estimate.suggest", "--validate-plugin", "docs/plugins/example-tool"]
    #expect(CubiCommand.toolRun(validate)?.args == ["--validate-plugin", "docs/plugins/example-tool"])
    // Every mode, appended after a tool-run, stays an argument.
    for m in CubiCommand.modes {
        let argv = ["cubi", "--tool-run", "nosuch", "x", m]
        #expect(CubiCommand.mode(argv) == "--tool-run" && CubiCommand.toolRun(argv)?.args == [m], "\(m)")
    }
    #expect(CubiCommand.toolRun(["cubi", "--tool-run", "sprint"]) == nil)
    #expect(CubiCommand.toolRun(["cubi", "--version", "sprint", "x"]) == nil)
}

/// What a restricted session may run is the allow rule's command and anything after it; whatever
/// it appends lands in the action's arguments, and sprint's handed-back actions take exactly one.
@Test func whatARestrictedSessionAppendsIsRefusedByTheArgumentCheck() throws {
    let cubi = "/Users/me/Applications/Cubi.app/Contents/MacOS/cubi"
    let rule = try #require(SessionLaunch.allowRule(cubi: cubi, tool: "sprint", action: "estimate.suggest"))
    // "Bash(<command>:*)" → the words a matching command line starts with.
    let words = rule.dropFirst("Bash(".count).dropLast(":*)".count).split(separator: " ").map(String.init)
    #expect(words == [cubi, "--tool-run", "sprint", "estimate.suggest"])
    // The review's escape attempt: a session pointed at a project with a prompt.
    let argv = words + ["x", "--new-session", "~/某專案", "--prompt", "…"]
    let run = try #require(CubiCommand.toolRun(argv))
    #expect(run.args == ["x", "--new-session", "~/某專案", "--prompt", "…"])
    let sprint = try ToolPlugin.load(url: repo.appendingPathComponent("docs/plugins/sprint/manifest.json"), home: "/Users/me")
    #expect(throws: ToolPlugin.InvokeError.argumentCount(expected: 1, got: 5)) { try sprint.invocation(action: run.action, args: run.args) }
}

@Test func anActionNameNeverStartsLikeAFlag() {
    for m in CubiCommand.modes { #expect(!ToolPlugin.isValidActionName(m), "\(m)") }
    #expect(!ToolPlugin.isValidActionName("--install-hooks") && !ToolPlugin.isValidActionName("--version"))
    // Names that start with `.` or `_` from the sprint plugin's own code (store.py:75 the lock file
    // `.lock`, sprint.py:78 the result key `_raw`), and one that starts with a digit from the docs
    // (advanced.md: the Claude Code version `2.1.322`), which is all letters-digits-dots.
    #expect(!ToolPlugin.isValidActionName(".lock") && !ToolPlugin.isValidActionName("_raw"))
    #expect(ToolPlugin.isValidActionName("2.1.322"))
}
