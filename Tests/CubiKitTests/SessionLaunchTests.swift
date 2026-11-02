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
