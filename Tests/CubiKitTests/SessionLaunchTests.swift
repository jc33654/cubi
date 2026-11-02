import Testing
@testable import CubiKit

@Test func launchCommandQuotesDirectoryWithSpaces() {
    #expect(SessionLaunch.command(directory: "/Users/me/My Project", prompt: nil, continueLast: false)
            == "cd '/Users/me/My Project' && claude")
}

@Test func launchCommandPassesPromptThroughSingleQuotes() {
    let cmd = SessionLaunch.command(directory: "/p", prompt: "it's \"a\" test\nline two", continueLast: false)
    #expect(cmd == "cd '/p' && claude 'it'\\''s \"a\" test\nline two'")
}

@Test func launchCommandContinueAndBlankPrompt() {
    #expect(SessionLaunch.command(directory: "/p", prompt: "   \n", continueLast: true) == "cd '/p' && claude --continue")
    #expect(SessionLaunch.command(directory: "/p", prompt: "hi", continueLast: true) == "cd '/p' && claude --continue 'hi'")
}
