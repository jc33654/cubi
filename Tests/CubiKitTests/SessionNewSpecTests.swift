import Foundation
import Testing
@testable import CubiKit

/// The built-in `session.new` as a plugin's panel sends it (PRD F8). Directories exist by a
/// fixed list here, so nothing depends on this machine's files; the on-disk DirectoryGuard is
/// left out (`refuses`), its own tests use real folders.
private let existing: Set<String> = ["/proj", "/proj/回顧 資料", "/data 📁", "/a", "/b"]
private func parse(_ json: String) throws -> SessionNewSpec {
    try SessionNewSpec.parse(json, promptLimit: 20, home: "/Users/me", refuses: { _ in false }) { existing.contains($0) || $0.hasPrefix("/Users/me") || $0 == "/" }
}
private func refusal(_ json: String) -> SessionNewSpec.ParseError? {
    do { _ = try parse(json); return nil } catch { return error as? SessionNewSpec.ParseError }
}

@Test func sessionNewAsItWasBeforeRestrictedMode() {   // F8-2: directory and prompt only
    #expect(try! parse(#"{"directory":"/proj","prompt":"第一句話"}"#) == SessionNewSpec(directory: "/proj", prompt: "第一句話", restricted: false, readDirs: []))
    #expect(try! parse(#"{"directory":"/proj/../proj/"}"#).directory == "/proj")
    #expect(try! parse(#"{"directory":"/proj","prompt":""}"#).prompt == nil)
    #expect(try! parse(#"{"directory":"/proj","prompt":"123456789012345678901234567890"}"#).prompt == "12345678901234567890")
    #expect(try! parse(#"{"directory":"/proj","restricted":false,"readDirs":[]}"#).restricted == false)
    // Unchanged messages for what was refused before.
    for bad in ["", "not json", "[]", #"{"prompt":"x"}"#, #"{"directory":""}"#, #"{"directory":7}"#] {
        #expect(refusal(bad) == .shape, "\(bad)")
    }
    #expect(SessionNewSpec.ParseError.shape.message == "session.new 要 args[0] 是 {\"directory\", \"prompt\"} 的 JSON")
    #expect(refusal(#"{"directory":"/nowhere"}"#) == .noDirectory("/nowhere"))
    #expect(SessionNewSpec.ParseError.noDirectory("/nowhere").message == "找不到目錄 /nowhere")
    #expect(refusal(#"{"directory":"relative/path"}"#) == .noDirectory("relative/path"))
    #expect((try? SessionNewSpec.parse(nil, promptLimit: 20) { _ in true }) == nil)
}

@Test func sessionNewRestrictedWithReadDirs() {   // F8-1
    let spec = try! parse(#"{"directory":"/proj","prompt":"讀資料","restricted":true,"readDirs":["/proj/回顧 資料","/data 📁","/proj/回顧 資料/"]}"#)
    #expect(spec == SessionNewSpec(directory: "/proj", prompt: "讀資料", restricted: true, readDirs: ["/proj/回顧 資料", "/data 📁"]))
    #expect(try! parse(#"{"directory":"/proj","restricted":true}"#).readDirs == [])
    #expect(try! parse(#"{"directory":"/proj","restricted":true,"readDirs":null}"#).readDirs == [])
}

@Test func sessionNewTakesTheModeNeverFlags() {   // F8-3
    #expect(refusal(#"{"directory":"/proj","restricted":"--dangerously-skip-permissions"}"#) == .restrictedNotBool)
    #expect(refusal(#"{"directory":"/proj","restricted":1}"#) == .restrictedNotBool)
    #expect(refusal(#"{"directory":"/proj","restricted":"true"}"#) == .restrictedNotBool)
    #expect(refusal(#"{"directory":"/proj","restricted":[true]}"#) == .restrictedNotBool)
    #expect(refusal(#"{"directory":"/proj","flags":["--x"]}"#) == .unknownField("flags"))
    #expect(refusal(#"{"directory":"/proj","restricted":true,"tools":"Bash"}"#) == .unknownField("tools"))
    #expect(refusal(#"{"directory":"/proj","Restricted":true}"#) == .unknownField("Restricted"))
    #expect(refusal(#"{"directory":"/proj","zz":1,"aa":2}"#) == .unknownField("aa"))
}

@Test func sessionNewReadDirsMustBeDirectoriesThatExistAndOnlyWhenRestricted() {   // F8-3
    #expect(refusal(#"{"directory":"/proj","restricted":true,"readDirs":["/a","/nowhere"]}"#) == .noReadDir("/nowhere"))
    #expect(refusal(#"{"directory":"/proj","restricted":true,"readDirs":["relative"]}"#) == .noReadDir("relative"))
    #expect(refusal(#"{"directory":"/proj","restricted":true,"readDirs":"/a"}"#) == .readDirsShape)
    #expect(refusal(#"{"directory":"/proj","restricted":true,"readDirs":["/a",7]}"#) == .readDirsShape)
    #expect(refusal(#"{"directory":"/proj","restricted":true,"readDirs":[""]}"#) == .readDirsShape)
    #expect(refusal(#"{"directory":"/proj","readDirs":["/a"]}"#) == .readDirsWithoutRestricted)
    #expect(refusal(#"{"directory":"/proj","restricted":false,"readDirs":["/a"]}"#) == .readDirsWithoutRestricted)
    let nine = Array(repeating: "\"/a\"", count: 9).joined(separator: ",")
    #expect(refusal(#"{"directory":"/proj","restricted":true,"readDirs":["# + nine + "]}") == .tooManyReadDirs)
    let eight = Array(repeating: "\"/a\"", count: 8).joined(separator: ",")
    #expect(try! parse(#"{"directory":"/proj","restricted":true,"readDirs":["# + eight + "]}").readDirs == ["/a"])
}

@Test func sessionNewQuestionSaysWhatTheUserAgreesTo() {   // F8-4
    let plain = SessionNewSpec(directory: "/proj", prompt: "hi", restricted: false, readDirs: [])
    #expect(plain.confirmation() == "目錄：/proj\n要交給 Claude 的話：hi")
    #expect(SessionNewSpec(directory: "/proj", prompt: nil, restricted: false, readDirs: []).confirmation().hasSuffix("（沒有）"))
    let long = String(repeating: "字", count: 401)
    #expect(SessionNewSpec(directory: "/p", prompt: long, restricted: false, readDirs: []).confirmation()
            == "目錄：/p\n要交給 Claude 的話：" + String(repeating: "字", count: 400) + "…（共 401 字）")

    // Restricted: nothing is asked, and what it may run is named.
    let restricted = SessionNewSpec(directory: "/proj", prompt: "hi", restricted: true, readDirs: ["/a", "/b"], allowActions: ["review.update", "x.y"])
    #expect(restricted.confirmation() == "目錄：/proj\n要交給 Claude 的話：hi\n"
            + "受限模式：不套用你的允許規則，也不會問你。只能執行這些動作：review.update、x.y；其他指令一律拒絕。\n另外可以讀：/a、/b")
    let readOnly = SessionNewSpec(directory: "/proj", prompt: "hi", restricted: true, readDirs: [])
    #expect(readOnly.confirmation().hasSuffix("受限模式：不套用你的允許規則，也不會問你。它只能讀檔，會改動東西的指令一律拒絕。"))
    for text in [restricted.confirmation(), readOnly.confirmation()] {
        #expect(!text.contains("核准") && !text.contains("總是允許") && !text.contains("hooks"))
    }
}

@Test func sessionNewAllowsOnlyActionsTheManifestMarked() {   // F8-29, F8-35
    func parse(_ json: String) throws -> SessionNewSpec {
        try SessionNewSpec.parse(json, promptLimit: 20, home: "/Users/me", actions: ["review.update", "notes.add"], refuses: { _ in false }) { existing.contains($0) }
    }
    func refusal(_ json: String) -> SessionNewSpec.ParseError? {
        do { _ = try parse(json); return nil } catch { return error as? SessionNewSpec.ParseError }
    }
    #expect(try! parse(#"{"directory":"/proj","restricted":true,"allowActions":["review.update","notes.add","review.update"]}"#).allowActions == ["review.update", "notes.add"])
    #expect(try! parse(#"{"directory":"/proj","restricted":true}"#).allowActions == [])
    #expect(try! parse(#"{"directory":"/proj","restricted":true,"allowActions":[]}"#).allowActions == [])
    #expect(try! parse(#"{"directory":"/proj","allowActions":null}"#).allowActions == [])
    // A name the plugin has, but did not mark; a name it does not have; a command line; a rule.
    for name in ["config.set", "nope", "review.update && rm -rf ~", "Bash(*)", "review.updateX", " review.update", "REVIEW.UPDATE"] {
        #expect(refusal(#"{"directory":"/proj","restricted":true,"allowActions":[""# + name + #""]}"#) == .unknownAction(name), "\(name)")
    }
    #expect(refusal(#"{"directory":"/proj","restricted":true,"allowActions":"review.update"}"#) == .allowActionsShape)
    #expect(refusal(#"{"directory":"/proj","restricted":true,"allowActions":["review.update",7]}"#) == .allowActionsShape)
    #expect(refusal(#"{"directory":"/proj","restricted":true,"allowActions":[""]}"#) == .allowActionsShape)
    #expect(refusal(#"{"directory":"/proj","allowActions":["review.update"]}"#) == .allowActionsWithoutRestricted)
    #expect(refusal(#"{"directory":"/proj","restricted":false,"allowActions":["review.update"]}"#) == .allowActionsWithoutRestricted)
    let five = Array(repeating: "\"review.update\"", count: 5).joined(separator: ",")
    #expect(refusal(#"{"directory":"/proj","restricted":true,"allowActions":["# + five + "]}") == .tooManyAllowActions)
    // A plugin that marked nothing can allow nothing.
    #expect(throws: SessionNewSpec.ParseError.unknownAction("review.update")) {
        try SessionNewSpec.parse(#"{"directory":"/proj","restricted":true,"allowActions":["review.update"]}"#, promptLimit: 20, refuses: { _ in false }) { _ in true }
    }
}

@Test func restrictedSettingsHoldOnlyCubisHooks() {   // F8-1: what --settings points at
    let settings = ClaudeHookInstaller.hooksOnlySettings()
    #expect(settings.object?.keys.sorted() == ["hooks"])
    // The same hooks an install writes, each command marked so the relay can say the session is restricted.
    let installed = ClaudeHookInstaller.installPlan(settings: .object([:])).after
    let commands = { (v: JSONValue) in ClaudeHookInstaller.events.flatMap { e in (v["hooks"]?[e.name]?.array ?? []).flatMap { ($0["hooks"]?.array ?? []).compactMap { $0["command"]?.string } } } }
    #expect(commands(settings).count == commands(installed).count)
    #expect(commands(settings) == commands(installed).map { $0.replacingOccurrences(of: "--agent claude-code --event", with: "--agent claude-code --restricted --event") })
    #expect(commands(settings).allSatisfy { $0.contains(" --restricted ") })
    #expect(commands(installed).allSatisfy { !$0.contains("--restricted") })
    #expect(ClaudeHookInstaller.status(settings).hooksInstalled)
    #expect(!ClaudeHookInstaller.status(settings).statuslineChained)
    for event in ClaudeHookInstaller.events {
        #expect(settings["hooks"]?[event.name]?.array?.allSatisfy { ClaudeHookInstaller.groupIsOurs($0) } == true, "\(event.name)")
    }
}

@Test func envelopeCarriesTheRestrictedMarkOnlyWhenTheRelayWasToldTo() throws {   // F8-14
    let plain = #"{"v":1,"agent":"claude-code","event":"PermissionRequest","tool":null,"pid":1,"ppid":2,"client":{"term_program":"ghostty","bundle_id":null,"term_session_id":null,"tty":"/dev/ttys009"},"payload":{"session_id":"s"}}"#
    let marked = plain.replacingOccurrences(of: #""tty":"/dev/ttys009""#, with: #""tty":"/dev/ttys009","restricted":true"#)
    #expect(try HookEnvelope.parse(Data(plain.utf8)).client.restricted == nil)
    #expect(try HookEnvelope.parse(Data(marked.utf8)).client.restricted == true)
    // A client without the mark encodes without the key: what is stored and replayed is unchanged.
    let encoded = String(decoding: try JSONEncoder().encode(HookClient(termProgram: "ghostty", tty: "/dev/ttys009")), as: UTF8.self)
    #expect(!encoded.contains("restricted"))
    #expect(String(decoding: try JSONEncoder().encode(HookClient(restricted: true)), as: UTF8.self).contains(#""restricted":true"#))
}

@Test func aRestrictedSessionIsNeverOfferedAlwaysAllow() {   // F8-15
    let some = JSONValue.array([.object(["type": .string("addRules")])])
    #expect(HookClient().offersAlwaysAllow(suggestions: some))
    #expect(HookClient(restricted: false).offersAlwaysAllow(suggestions: some))
    #expect(!HookClient(restricted: true).offersAlwaysAllow(suggestions: some))
    // Nothing to add: no offer, as before.
    #expect(!HookClient().offersAlwaysAllow(suggestions: .array([])))
    #expect(!HookClient().offersAlwaysAllow(suggestions: .null))
}

@Test func restrictedSettingsKeepEveryLayersDenyRulesAndNothingElse() {   // F8-17
    let user: JSONValue = .object(["permissions": .object(["deny": .array([.string("Read(**/.env)"), .string("Read(~/.ssh/**)")]),
                                                           "allow": .array([.string("Bash(python3:*)")]), "ask": .array([.string("Bash(git push:*)")]),
                                                           "defaultMode": .string("acceptEdits")]),
                                   "statusLine": .object(["type": .string("command"), "command": .string("x")]), "env": .object(["A": .string("1")])])
    let project: JSONValue = .object(["permissions": .object(["deny": .array([.string("Read(./secrets/**)"), .string("Read(**/.env)")]), "allow": .array([.string("Bash(make:*)")])])])
    let local: JSONValue = .object(["permissions": .object(["deny": .array([.string("Bash(curl:*)")]), "allow": .array([.string("Bash(*)")])])])
    let settings = ClaudeHookInstaller.restrictedSettings(denyingAs: [.user(user), .project(project, workingDirectory: "/w"), .project(local, workingDirectory: "/w")])
    #expect(settings.object?.keys.sorted() == ["hooks", "permissions"])
    #expect(settings["permissions"]?.object?.keys.sorted() == ["blockReadsOutsideWorkingDirectories", "deny", "disableAutoMode", "disableBypassPermissionsMode"])
    #expect(settings["permissions"]?["deny"] == .array([.string("Read(**/.env)"), .string("Read(~/.ssh/**)"), .string("Read(./secrets/**)"), .string("Bash(curl:*)")]))
    #expect(settings["hooks"] == ClaudeHookInstaller.hooksOnlySettings()["hooks"])
    let text = String(decoding: SettingsFile.serialize(settings), as: UTF8.self)
    for forbidden in ["\"allow\"", "python3", "make:", "Bash(*)", "\"ask\"", "git push", "defaultMode", "statusLine", "\"env\""] {
        #expect(!text.contains(forbidden), "\(forbidden)")
    }
    // No deny rules anywhere (or no files at all): the hooks and the two switches, no deny key.
    let pins: JSONValue = .object(["disableAutoMode": .string("disable"), "disableBypassPermissionsMode": .string("disable"), "blockReadsOutsideWorkingDirectories": .bool(true)])
    for layers in [[], [.user(.object([:])), .project(.object(["permissions": .object(["allow": .array([.string("Bash(*)")])])]), workingDirectory: "/w")]] as [[ClaudeHookInstaller.DenyLayer]] {
        let bare = ClaudeHookInstaller.restrictedSettings(denyingAs: layers)
        #expect(bare["permissions"] == pins)
        #expect(bare["hooks"] == ClaudeHookInstaller.hooksOnlySettings()["hooks"])
    }
}

@Test func restrictedSettingsAlwaysSwitchAutoAndBypassOff() {   // F8-24
    let user: JSONValue = .object(["permissions": .object(["deny": .array([.string("Read(**/.env)")]), "defaultMode": .string("auto"),
                                                           "disableAutoMode": .string("enable"), "disableBypassPermissionsMode": .string("enable"),
                                                           "blockReadsOutsideWorkingDirectories": .bool(false)])])
    for hooks in [true, false] {
        let settings = ClaudeHookInstaller.restrictedSettings(denyingAs: [.user(user)], hooks: hooks)
        // Whatever the user's own file says about them, these two are Cubi's to set.
        #expect(settings["permissions"]?["disableAutoMode"] == .string("disable"))
        #expect(settings["permissions"]?["disableBypassPermissionsMode"] == .string("disable"))
        #expect(settings["permissions"]?["blockReadsOutsideWorkingDirectories"] == .bool(true))   // F8-36
        #expect(settings["permissions"]?["deny"] == .array([.string("Read(**/.env)")]))
        #expect(settings["permissions"]?["defaultMode"] == nil)
        // Without Cubi's hooks installed the file has no hooks, and still everything else (F8-12).
        #expect((settings["hooks"] != nil) == hooks)
        #expect(settings.object?.keys.sorted() == (hooks ? ["hooks", "permissions"] : ["permissions"]))
    }
}

@Test func sessionNewNeverHandsOverTheHomeDirectoryOrWhereKeysLive() {
    for path in ["/", "/Users/me", "/Users/me/", "~", "/Users/me/.ssh", "/Users/me/.ssh/keys", "~/.aws", "/Users/me/.gnupg", "/Users/me/.config/atlassian", "/Users/me/Library/Keychains"] {
        #expect({ if case .privateReadDir = refusal(#"{"directory":"/proj","restricted":true,"readDirs":[""# + path + #""]}"#) { return true } else { return false } }(), "\(path)")
    }
    // Ordinary folders under home are fine, as is a name that only starts like a private one.
    #expect(try! parse(#"{"directory":"/proj","restricted":true,"readDirs":["/Users/me/Documents/回顧","/Users/me/.sshconfig-notes"]}"#).readDirs
            == ["/Users/me/Documents/回顧", "/Users/me/.sshconfig-notes"])
    // Batch 37: the working directory is held to the same rule (the session reads all of it).
    for path in ["/", "/Users/me", "~", "/Users/me/.ssh", "/Users/me/.aws/x"] {
        #expect(refusal(#"{"directory":""# + path + #""}"#) == .guardedDirectory((path as NSString).expandingTildeInPath == path ? path : "/Users/me"), "\(path)")
    }
    #expect(try! parse(#"{"directory":"/Users/me/Documents/proj"}"#).directory == "/Users/me/Documents/proj")
}

@Test func sessionNewAsksTheGuardAboutTheDirectoryAndEveryReadDir() {
    var asked: [String] = []
    func parse(_ json: String, refusing: String) throws -> SessionNewSpec {
        try SessionNewSpec.parse(json, promptLimit: 20, home: "/Users/me", refuses: { asked.append($0); return $0 == refusing }) { existing.contains($0) }
    }
    _ = try? parse(#"{"directory":"/proj","restricted":true,"readDirs":["/a","/b"]}"#, refusing: "")
    #expect(asked == ["/proj", "/a", "/b"])
    #expect(throws: SessionNewSpec.ParseError.guardedDirectory("/proj")) { try parse(#"{"directory":"/proj"}"#, refusing: "/proj") }
    #expect(throws: SessionNewSpec.ParseError.privateReadDir("/b")) { try parse(#"{"directory":"/proj","restricted":true,"readDirs":["/a","/b"]}"#, refusing: "/b") }
    #expect(SessionNewSpec.ParseError.guardedDirectory("/x").message.hasPrefix("不能在 /x 開 session"))
}

@Test func denyRulesAnchoredToTheirFileAreRewrittenToMeanTheSameElsewhere() {   // F8-19
    func deny(_ rules: [String]) -> JSONValue { .object(["permissions": .object(["deny": .array(rules.map { .string($0) })])]) }
    let settings = ClaudeHookInstaller.restrictedSettings(denyingAs: [
        .user(deny(["Read(/notes/**)", "Read(**/.env)", "Read(~/.ssh/**)", "Read(//etc/passwd)", "Bash(/usr/bin/curl:*)"])),
        .project(deny(["Read(/secrets/**)", "Edit(/config/prod.yml)", "Read(./local/**)", "Read(build/**)", "WebFetch(domain:example.com)"]), workingDirectory: "/Users/me/My Proj 專案"),
        .project(deny(["Write(/x)", "Grep(/logs/**)", "Read(/secrets/**)", "mcp__server__tool"]), workingDirectory: "/Users/me/My Proj 專案"),
    ])
    #expect(settings["permissions"]?["deny"] == .array([
        .string("Read(~/.claude/notes/**)"), .string("Read(**/.env)"), .string("Read(~/.ssh/**)"), .string("Read(//etc/passwd)"), .string("Bash(/usr/bin/curl:*)"),
        .string("Read(//Users/me/My Proj 專案/secrets/**)"), .string("Edit(//Users/me/My Proj 專案/config/prod.yml)"), .string("Read(./local/**)"), .string("Read(build/**)"),
        .string("WebFetch(domain:example.com)"),
        .string("Write(//Users/me/My Proj 專案/x)"), .string("Grep(//Users/me/My Proj 專案/logs/**)"), .string("mcp__server__tool"),
    ]))
    // One rule at a time: every path tool, and what must stay as written.
    for tool in ClaudeHookInstaller.pathTools {
        #expect(ClaudeHookInstaller.portableDenyRule("\(tool)(/a/b)", anchor: "//w") == "\(tool)(//w/a/b)")
        #expect(ClaudeHookInstaller.portableDenyRule("\(tool)(//a/b)", anchor: "//w") == "\(tool)(//a/b)")
    }
    for same in ["Read", "Read()", "Read(a/b)", "Read(~/a)", "Read(**/a)", "Read(./a)", "Bash(/bin/rm:*)", "Bash(rm -rf /)", "NotATool(/a)", "/a", "Read(/a", ""] {
        #expect(ClaudeHookInstaller.portableDenyRule(same, anchor: "//w") == same, "\(same)")
    }
}

@Test func theLocalSettingsOfARepositoryAreReadFromItsRoot() {   // F8-21
    let git: Set<String> = ["/Users/me/proj/.git", "/Users/me/.git", "/.git", "/srv/repo/.git"]
    func root(_ dir: String) -> String { ClaudeHookInstaller.localSettingsDirectory(for: dir, home: "/Users/me") { git.contains($0) } }
    #expect(root("/Users/me/proj") == "/Users/me/proj")
    #expect(root("/Users/me/proj/docs/回顧 資料") == "/Users/me/proj")
    #expect(root("/srv/repo/a/b") == "/srv/repo")
    // Not in a repository: the directory itself. The home directory and the root never count as one.
    #expect(root("/Users/me/notes/2026") == "/Users/me/notes/2026")
    #expect(root("/Users/me") == "/Users/me")
    #expect(root("/opt/x") == "/opt/x")
    #expect(root("/") == "/")
}
