import Foundation
import Testing
@testable import CubiKit

@Test func launchCommandQuotesDirectoryWithSpaces() {
    #expect(SessionLaunch.command(directory: "/Users/me/My Project", prompt: nil, resume: .none)
            == "cd '/Users/me/My Project' && claude")
}

@Test func launchCommandPassesPromptThroughSingleQuotesAfterDoubleDash() {
    let cmd = SessionLaunch.command(directory: "/p", prompt: "it's \"a\" test\nline two", resume: .none)
    #expect(cmd == "cd '/p' && claude -- 'it'\\''s \"a\" test\nline two'")
}

@Test func launchCommandPromptStartingWithDashIsNotAnOption() {
    #expect(SessionLaunch.command(directory: "/p", prompt: "--version x", resume: .none) == "cd '/p' && claude -- '--version x'")
}

@Test func launchCommandResumeVariantsAndBlankPrompt() {
    #expect(SessionLaunch.command(directory: "/p", prompt: "   \n", resume: .last) == "cd '/p' && claude --continue")
    #expect(SessionLaunch.command(directory: "/p", prompt: "hi", resume: .session("abc-1")) == "cd '/p' && claude --resume 'abc-1' -- 'hi'")
}

// MARK: - Restricted mode (PRD F8)

@Test func restrictedLaunchCarriesTheFixedFlagsBeforeTheDoubleDash() {   // F8-1, F8-11
    let cmd = SessionLaunch.command(directory: "/Users/me/My Notes", prompt: "讀 it's 資料 🎯", resume: .none,
                                    restricted: .init(settingsFile: "/Users/me/.cubi/restricted-settings.json", readDirs: ["/Users/me/回顧 資料/📁"]))
    #expect(cmd == "cd '/Users/me/My Notes' && claude --restricted --permission-mode dontAsk --strict-mcp-config --disable-slash-commands --tools 'Read,Grep,Glob,Bash'"
                 + " --settings '/Users/me/.cubi/restricted-settings.json' --add-dir '/Users/me/回顧 資料/📁' -- '讀 it'\\''s 資料 🎯'")
    // `--tools` and `--add-dir` take any number of values: nothing but options between them and `--`.
    let options = cmd.components(separatedBy: " -- ")[0]
    #expect(options.hasSuffix("--add-dir '/Users/me/回顧 資料/📁'"))
    #expect(cmd.components(separatedBy: " -- ").count == 2)
}

@Test func restrictedLaunchWithoutReadDirsOrPrompt() {   // F8-12: the settings file is passed whether or not Cubi's hooks are in it
    #expect(SessionLaunch.command(directory: "/p", prompt: "hi", resume: .none, restricted: .init(settingsFile: "/s.json", readDirs: []))
            == "cd '/p' && claude --restricted --permission-mode dontAsk --strict-mcp-config --disable-slash-commands --tools 'Read,Grep,Glob,Bash' --settings '/s.json' -- 'hi'")
    // No prompt: the options still end in `--`, so the last one's value list is closed.
    #expect(SessionLaunch.command(directory: "/p", prompt: nil, resume: .none, restricted: .init(settingsFile: "/s.json", readDirs: ["/a", "/b"]))
            == "cd '/p' && claude --restricted --permission-mode dontAsk --strict-mcp-config --disable-slash-commands --tools 'Read,Grep,Glob,Bash' --settings '/s.json' --add-dir '/a' --add-dir '/b' --")
}

@Test func launchWithoutRestrictedIsWhatItAlwaysWas() {   // F8-2
    for (prompt, resume) in [(nil, SessionLaunch.Resume.none), ("it's", .none), ("hi", .last), ("-x", .session("abc-1"))] as [(String?, SessionLaunch.Resume)] {
        #expect(SessionLaunch.command(directory: "/p q", prompt: prompt, resume: resume, restricted: nil)
                == SessionLaunch.command(directory: "/p q", prompt: prompt, resume: resume))
    }
    #expect(SessionLaunch.command(directory: "/p", prompt: "hi", resume: .none) == "cd '/p' && claude -- 'hi'")
    #expect(!SessionLaunch.command(directory: "/p", prompt: nil, resume: .none).contains("--"))
}

@Test func aQuoteInAReadDirCannotLeaveItsArgument() {
    let cmd = SessionLaunch.command(directory: "/p", prompt: nil, resume: .none,
                                    restricted: .init(settingsFile: "/s.json", readDirs: ["/tmp/x' --dangerously-skip-permissions '"]))
    #expect(cmd.hasSuffix("--add-dir '/tmp/x'\\'' --dangerously-skip-permissions '\\''' --"))
}

@Test func aRestrictedSessionNeverAsksWhateverModeTheUserLastHad() {   // F8-22
    for restricted in [SessionLaunch.Restricted(settingsFile: "/s.json", readDirs: []), .init(settingsFile: "/s 設定.json", readDirs: ["/a"])] {
        for prompt in [nil, "hi"] as [String?] {
            let options = SessionLaunch.command(directory: "/p", prompt: prompt, resume: .none, restricted: restricted).components(separatedBy: " -- ")[0]
            #expect(options.contains(" --permission-mode dontAsk "))
            #expect(options.contains(" --disable-slash-commands "))
            #expect(options.contains(" --settings '\(restricted.settingsFile)'"))   // the file that keeps it out of auto: never left out
            #expect(!options.contains("auto") && !options.contains("bypassPermissions") && !options.contains("manual") && !options.contains("acceptEdits"))
        }
    }
    // Not restricted: the mode is the user's own business, as before.
    #expect(!SessionLaunch.command(directory: "/p", prompt: "hi", resume: .none).contains("--permission-mode"))
}

// MARK: - Commands too long to type

@Test func aShortCommandIsTypedAsItIs() {
    let command = SessionLaunch.command(directory: "/p", prompt: "hi", resume: .none)
    let typed = SessionLaunch.typed(command, scriptPath: "/Users/me/.cubi/launch/x.sh")
    #expect(typed.line == command)
    #expect(typed.script == nil)
}

@Test func aLongCommandIsReadFromAFileByOneShortLine() {
    // The sprint review's first prompt is about 340 characters, 740 bytes: with the restricted
    // flags and two real paths the command passes a terminal line's 1024 bytes.
    let prompt = String(repeating: "請讀回顧資料，", count: 48)
    let command = SessionLaunch.command(directory: "/Users/me/Documents/project notes", prompt: prompt, resume: .none,
                                        restricted: .init(settingsFile: "/Users/me/.cubi/restricted-settings.json", readDirs: ["/Users/me/Documents/project notes/回顧"]))
    #expect(command.utf8.count > 1024)
    let typed = SessionLaunch.typed(command, scriptPath: "/Users/me/.cubi/launch/it's 啟動 🎯.sh")
    #expect(typed.line == "source '/Users/me/.cubi/launch/it'\\''s 啟動 🎯.sh'")
    #expect(typed.line.utf8.count < SessionLaunch.maxTypedBytes)
    #expect(typed.script == command + "\n")
}

@Test func whatIsTypedAlwaysFitsATerminalLine() {
    #expect(SessionLaunch.maxTypedBytes < 1024)
    for bytes in [1, 100, SessionLaunch.maxTypedBytes - 2, SessionLaunch.maxTypedBytes - 1, SessionLaunch.maxTypedBytes, SessionLaunch.maxTypedBytes + 1, 1016, 1023, 1024, 5000] {
        let command = String(repeating: "x", count: bytes)
        let typed = SessionLaunch.typed(command, scriptPath: "/Users/me/.cubi/launch/0E9A1B7C-0000-0000-0000-000000000000.sh")
        #expect(typed.line.utf8.count + 1 <= SessionLaunch.maxTypedBytes, "\(bytes)")
        #expect((typed.script == nil) == (bytes + 1 <= SessionLaunch.maxTypedBytes), "\(bytes)")
        #expect(typed.script == nil || typed.script == command + "\n")
    }
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func theLaunchFileAndItsFolderAreTheUsersOnlyEvenIfTheFolderWasNot() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("cubi-launch-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    // The folder is already there and open to everyone, as if something else had made it.
    let folder = root.appendingPathComponent("launch 啟動 🎯")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
    #expect(mode(folder) == 0o777)
    let file = folder.appendingPathComponent("a.sh")
    try SessionLaunch.writeScript("cd '/p' && claude -- '第一句話 🎯'\n", to: file)
    #expect(mode(folder) == 0o700)
    #expect(mode(file) == 0o600)
    #expect(try String(contentsOf: file, encoding: .utf8) == "cd '/p' && claude -- '第一句話 🎯'\n")
    // Loosened again between two launches: put right again.
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    try SessionLaunch.writeScript("x\n", to: folder.appendingPathComponent("b.sh"))
    #expect(mode(folder) == 0o700)
    // A folder that is not there yet is made, the same way.
    let fresh = root.appendingPathComponent("new/launch")
    try SessionLaunch.writeScript("x\n", to: fresh.appendingPathComponent("c.sh"))
    #expect(mode(fresh) == 0o700)
    #expect(mode(fresh.appendingPathComponent("c.sh")) == 0o600)
}

@Test func launchFilesOlderThanAnHourAreClearedAndNothingElseIs() throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("cubi-launch-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: folder) }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let now = Date()
    for (name, age) in [("old.sh", 3601.0), ("recent.sh", 3599.0), ("fresh.sh", 2.0), ("notes.txt", 99_999.0)] {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    try SessionLaunch.writeScript("y\n", to: folder.appendingPathComponent("new.sh"), now: now)
    #expect(try fm.contentsOfDirectory(atPath: folder.path).sorted() == ["fresh.sh", "new.sh", "notes.txt", "recent.sh"])
}

// MARK: - What a restricted session may run (PRD F8-29, F8-30, F8-32)

@Test func theRuleForAnActionIsTheOneThatPassedAgainstClaudeCode() {
    #expect(SessionLaunch.allowRule(cubi: "/Users/me/Applications/Cubi.app/Contents/MacOS/cubi", tool: "sprint", action: "review.update")
            == "Bash(/Users/me/Applications/Cubi.app/Contents/MacOS/cubi --tool-run sprint review.update:*)")
    #expect(SessionLaunch.allowRule(cubi: "/opt/cubi-1.2/bin/cubi_dev", tool: "my-tool", action: "a.b-c_d") == "Bash(/opt/cubi-1.2/bin/cubi_dev --tool-run my-tool a.b-c_d:*)")
}

@Test func noRuleForAPathOrNameThatWouldNeedQuoting() {   // F8-32
    let cubi = "/Applications/Cubi.app/Contents/MacOS/cubi"
    for bad in ["/Users/first last/Applications/Cubi.app/Contents/MacOS/cubi", "/Users/me/應用程式/cubi", "/x/cubi'", "/x/cu\"bi", "/x/cubi)", "/x/cubi;rm", "/x/$HOME/cubi",
                "/x/cu*bi", "~/Applications/Cubi.app/Contents/MacOS/cubi", "Applications/cubi", ""] {
        #expect(SessionLaunch.allowRule(cubi: bad, tool: "sprint", action: "review.update") == nil, "\(bad)")
    }
    for bad in ["review.update && rm", "review update", "review.update:*", "a/b", "更新", "", "x)"] {
        #expect(SessionLaunch.allowRule(cubi: cubi, tool: "sprint", action: bad) == nil, "\(bad)")
        #expect(SessionLaunch.allowRule(cubi: cubi, tool: bad, action: "review.update") == nil, "\(bad)")
    }
}

@Test func theAllowedCommandsComeLastBeforeTheDoubleDash() {
    let rule = "Bash(/Applications/Cubi.app/Contents/MacOS/cubi --tool-run sprint review.update:*)"
    let cmd = SessionLaunch.command(directory: "/p", prompt: "hi", resume: .none,
                                    restricted: .init(settingsFile: "/s.json", readDirs: ["/Users/me/Library/Application Support/cubi/sprint/briefs"], allowedTools: [rule, "Bash(/x/cubi --tool-run sprint b:*)"]))
    #expect(cmd == "cd '/p' && claude --restricted --permission-mode dontAsk --strict-mcp-config --disable-slash-commands --tools 'Read,Grep,Glob,Bash' --settings '/s.json'"
                 + " --add-dir '/Users/me/Library/Application Support/cubi/sprint/briefs' --allowedTools '\(rule)' 'Bash(/x/cubi --tool-run sprint b:*)' -- 'hi'")
    // None named: no --allowedTools at all, so nothing that needs asking can run.
    #expect(!SessionLaunch.command(directory: "/p", prompt: "hi", resume: .none, restricted: .init(settingsFile: "/s.json", readDirs: [])).contains("--allowedTools"))
    // …and `--allowedTools` takes any number of values: with no prompt the closing `--` still ends its list.
    #expect(SessionLaunch.command(directory: "/p", prompt: nil, resume: .none, restricted: .init(settingsFile: "/s.json", readDirs: [], allowedTools: [rule])).hasSuffix("--allowedTools '\(rule)' --"))
}
