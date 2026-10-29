import Foundation
import Testing
@testable import CubiKit

/// The shape of Jade's real ~/.claude/settings.json (hooks of her own, a statusLine, permissions).
private let jadeSettings: JSONValue = .object([
    "model": .string("fable"),
    "hooks": .object([
        "Notification": .array([.object(["matcher": .string(""), "hooks": .array([.object(["type": .string("command"), "command": .string("~/.claude/notify-hook.sh")])])])]),
        "Stop": .array([.object(["hooks": .array([.object(["type": .string("command"), "command": .string("python3 ~/.claude/hooks/zh-reply-guard.py"), "timeout": .number(10)])])])]),
    ]),
    "statusLine": .object(["type": .string("command"), "command": .string("~/.claude/statusline.sh")]),
    "permissions": .object(["allow": .array([.string("Bash(git status)")])]),
])

@Test func installAddsEveryEventAndKeepsForeignHooks() {
    let plan = ClaudeHookInstaller.installPlan(settings: jadeSettings)
    #expect(plan.changed)
    let hooks = plan.after["hooks"]!.object!
    for (event, _) in ClaudeHookInstaller.events { #expect(hooks[event] != nil, Comment(rawValue: event)) }
    #expect(hooks["Notification"]?.array?.count == 2)          // hers + ours
    #expect(hooks["Stop"]?.array?.count == 2)
    #expect(hooks["PreToolUse"]?.array?.count == 2)            // plain + AskUserQuestion matcher
    #expect(hooks["PreToolUse"]?.array?[1]["matcher"]?.string == "AskUserQuestion")
    #expect(hooks["PermissionRequest"]?.array?[0]["hooks"]?.array?[0]["timeout"]?.double == 120)
    #expect(plan.after["permissions"] == jadeSettings["permissions"])
    #expect(plan.after["model"]?.string == "fable")
}

@Test func installChainsStatuslineAndRemembersPrevious() {
    let plan = ClaudeHookInstaller.installPlan(settings: jadeSettings)
    #expect(plan.after["statusLine"]?["command"]?.string == "$HOME/.cubi/bin/cubi-hook --agent claude-code statusline --then '~/.claude/statusline.sh'")
    #expect(plan.previousStatusLine == jadeSettings["statusLine"])
    let status = ClaudeHookInstaller.status(plan.after)
    #expect(status.hooksInstalled && status.statuslineChained)
    #expect(status.legacyNotificationCommands == ["~/.claude/notify-hook.sh"])
}

@Test func installIsIdempotent() {
    let once = ClaudeHookInstaller.installPlan(settings: jadeSettings).after
    let twice = ClaudeHookInstaller.installPlan(settings: once)
    #expect(!twice.changed)
    #expect(twice.after == once)
    #expect(twice.previousStatusLine == nil)
}

@Test func uninstallRestoresTheOriginalExactly() {
    let plan = ClaudeHookInstaller.installPlan(settings: jadeSettings)
    let back = ClaudeHookInstaller.uninstallPlan(settings: plan.after, previousStatusLine: plan.previousStatusLine)
    #expect(back.after == jadeSettings)
    #expect(!ClaudeHookInstaller.status(back.after).hooksInstalled)
}

@Test func uninstallWithoutRecordRecoversStatuslineFromThen() {
    let installed = ClaudeHookInstaller.installPlan(settings: jadeSettings).after
    #expect(installed["statusLine"]?["command"]?.string == "$HOME/.cubi/bin/cubi-hook --agent claude-code statusline --then '~/.claude/statusline.sh'")
    let back = ClaudeHookInstaller.uninstallPlan(settings: installed, previousStatusLine: nil)
    #expect(back.after["statusLine"]?["command"]?.string == "~/.claude/statusline.sh")
}

@Test func chainedStatuslineKeepsQuotesAndPipesIntact() {
    let original = "jq -r '.model.display_name | ascii_upcase'"
    let settings: JSONValue = .object(["statusLine": .object(["type": .string("command"), "command": .string(original)])])
    let plan = ClaudeHookInstaller.installPlan(settings: settings)
    let quoted = "'jq -r '\\''.model.display_name | ascii_upcase'\\'''"
    #expect(plan.after["statusLine"]?["command"]?.string?.hasSuffix(" --then " + quoted) == true)
    let back = ClaudeHookInstaller.uninstallPlan(settings: plan.after, previousStatusLine: nil)
    #expect(back.after["statusLine"]?["command"]?.string == original)
}

@Test func uninstallKeepsOtherAgentsHooks() {
    let foreign: JSONValue = .object(["hooks": .array([.object(["type": .string("command"), "command": .string("$HOME/.cubi/bin/cubi-hook --agent other-agent --event SessionStart")])])])
    var s = ClaudeHookInstaller.installPlan(settings: jadeSettings).after.object!
    var hooks = s["hooks"]!.object!
    hooks["SessionStart"] = .array((hooks["SessionStart"]!.array ?? []) + [foreign])
    s["hooks"] = .object(hooks)
    let back = ClaudeHookInstaller.uninstallPlan(settings: .object(s), previousStatusLine: nil)
    #expect(back.after["hooks"]?["SessionStart"]?.array == [foreign])
}

@Test func retiringLegacyNotificationHook() {
    let plan = ClaudeHookInstaller.installPlan(settings: jadeSettings, retireCommandsContaining: ["notify-hook.sh"])
    #expect(plan.after["hooks"]?["Notification"]?.array?.count == 1)
    #expect(plan.after["hooks"]?["Stop"]?.array?.count == 2)   // unrelated hooks untouched
}

@Test func emptySettingsGetsAStatuslineWithoutThen() {
    let plan = ClaudeHookInstaller.installPlan(settings: .object([:]))
    #expect(plan.after["statusLine"]?["command"]?.string == "$HOME/.cubi/bin/cubi-hook --agent claude-code statusline")
    #expect(plan.previousStatusLine == nil)
}

@Test func diffShowsOnlyChangedRegions() {
    let plan = ClaudeHookInstaller.installPlan(settings: jadeSettings)
    #expect(plan.diff.contains("+"))
    #expect(plan.diff.contains("cubi-hook --agent claude-code --event PermissionRequest"))
    #expect(!plan.diff.contains("-    \"model\""))     // untouched key is not shown as removed
}

@Test func settingsFileRoundTripWithBackupAndCAS() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cubi-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("settings.json")
    let backups = dir.appendingPathComponent("backups")

    // Absent file reads as empty.
    let empty = try SettingsFile.read(at: url)
    #expect(empty.object == .object([:]) && empty.bytes == nil)

    // First write: no backup (nothing to back up).
    let v1 = SettingsFile.serialize(.object(["a": .number(1)]))
    #expect(try SettingsFile.write(v1, to: url, expecting: nil, backupDir: backups) == nil)
    let snap = try SettingsFile.read(at: url)
    #expect(snap.object["a"]?.double == 1 && snap.bytes == v1)

    // Second write: backup made, content replaced.
    let v2 = SettingsFile.serialize(.object(["a": .number(2)]))
    let backup = try SettingsFile.write(v2, to: url, expecting: v1, backupDir: backups)
    #expect(backup != nil && FileManager.default.fileExists(atPath: backup!.path))
    #expect(try Data(contentsOf: backup!) == v1)

    // Stale expectation is refused.
    #expect(throws: SettingsFile.Failure.changedSincePreview("settings.json")) {
        try SettingsFile.write(v1, to: url, expecting: v1, backupDir: backups)
    }

    // Invalid JSON is refused, not treated as empty.
    try Data("{not json".utf8).write(to: url)
    #expect(throws: SettingsFile.Failure.invalid("settings.json")) { try SettingsFile.read(at: url) }
}

@Test func agentTagIsTokenExact() {
    let fooBar: JSONValue = .object(["hooks": .array([.object(["type": .string("command"), "command": .string("$HOME/.cubi/bin/cubi-hook --agent foo-bar --event SessionStart")])])])
    let foo: JSONValue = .object(["hooks": .array([.object(["type": .string("command"), "command": .string("$HOME/.cubi/bin/cubi-hook --agent foo --event SessionStart")])])])
    #expect(!ClaudeHookInstaller.groupIsOurs(fooBar, agent: "foo"))
    #expect(ClaudeHookInstaller.groupIsOurs(foo, agent: "foo"))
    #expect(!ClaudeHookInstaller.groupIsOurs(foo, agent: "foo-bar"))
    // The status line command ends in "statusline", not "--event": the tag still has to match.
    let chained: JSONValue = .object(["hooks": .array([.object(["type": .string("command"), "command": .string("$HOME/.cubi/bin/cubi-hook --agent foo statusline")])])])
    #expect(ClaudeHookInstaller.groupIsOurs(chained, agent: "foo"))
}
