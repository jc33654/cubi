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
    #expect(cmd == "cd '/Users/me/My Notes' && claude --restricted --strict-mcp-config --tools 'Read,Grep,Glob,Bash'"
                 + " --settings '/Users/me/.cubi/restricted-settings.json' --add-dir '/Users/me/回顧 資料/📁' -- '讀 it'\\''s 資料 🎯'")
    // `--tools` and `--add-dir` take any number of values: nothing but options between them and `--`.
    let options = cmd.components(separatedBy: " -- ")[0]
    #expect(options.hasSuffix("--add-dir '/Users/me/回顧 資料/📁'"))
    #expect(cmd.components(separatedBy: " -- ").count == 2)
}

@Test func restrictedLaunchWithoutHooksOrReadDirsOrPrompt() {   // F8-12: no hooks installed, no --settings
    #expect(SessionLaunch.command(directory: "/p", prompt: "hi", resume: .none, restricted: .init(settingsFile: nil, readDirs: []))
            == "cd '/p' && claude --restricted --strict-mcp-config --tools 'Read,Grep,Glob,Bash' -- 'hi'")
    // No prompt: the options still end in `--`, so the last one's value list is closed.
    #expect(SessionLaunch.command(directory: "/p", prompt: nil, resume: .none, restricted: .init(settingsFile: nil, readDirs: ["/a", "/b"]))
            == "cd '/p' && claude --restricted --strict-mcp-config --tools 'Read,Grep,Glob,Bash' --add-dir '/a' --add-dir '/b' --")
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
                                    restricted: .init(settingsFile: nil, readDirs: ["/tmp/x' --dangerously-skip-permissions '"]))
    #expect(cmd.hasSuffix("--add-dir '/tmp/x'\\'' --dangerously-skip-permissions '\\''' --"))
}
