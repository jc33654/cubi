import Foundation
import Testing
@testable import CubiKit

@Test func claudeCodePluginMatchesTheDecoderAndReplies() throws {
    let plugin = ClaudeCodePlugin()
    #expect(plugin.id == "claude-code" && plugin.isBuiltIn)
    #expect(plugin.capabilities.contains(.approvals) && plugin.capabilities.contains(.questions))
    let env = try Fixtures.envelope("PermissionRequest-1")
    #expect(plugin.decode(env) == ClaudeCodeDecoder.decode(env))
    let ctx = PendingContext(kind: .approval, envelope: env)
    #expect(plugin.reply(.allow, for: ctx) == ClaudeCodeReplies.permission(.allow))
    #expect(plugin.reply(.always, for: ctx)?.contains("localSettings") == true)
    #expect(plugin.reply(.answers(["q": "a"]), for: ctx) == nil)   // answers do not fit an approval
    let q = try Fixtures.envelope("PreToolUse-AskUserQuestion-1")
    let qctx = PendingContext(kind: .questionPreToolUse, envelope: q)
    #expect(plugin.reply(.answers(["x": "y"]), for: qctx)?.contains("\"hookEventName\":\"PreToolUse\"") == true)
}

private func exampleManifest() throws -> ManifestPlugin {
    let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/plugins/example-agent")!
    return try ManifestPlugin.load(url: url)
}

@Test func manifestLoadsIdentityAndInstallEntries() throws {
    let p = try exampleManifest()
    #expect(p.id == "example-agent" && p.displayName == "Example Agent")
    #expect(p.accentColor == RGB(hex: 0x2DD4BF))
    #expect(p.capabilities == [.approvals])
    #expect(p.secrets.first?.key == "EXAMPLE_API_KEY")
    guard case .jsonHooks(let file) = p.installMode else { Issue.record("mode"); return }
    #expect(file == "~/.example-agent/settings.json")
    #expect(p.installEntries.count == 4)
    #expect(!p.isBuiltIn)
}

@Test func manifestDecodesWithJSONPathMap() throws {
    let p = try exampleManifest()
    let env = HookEnvelope(agent: "example-agent", event: "BeforeTool", payload: .object([
        "session_id": .string("s1"), "workdir": .string("/tmp/x"),
        "toolCall": .object(["name": .string("shell"), "args": .object(["cmd": .string("ls")])]),
    ]))
    let d = try #require(p.decode(env))
    #expect(d.session.id == "s1")
    guard case .toolStart(let tool, let input) = d.event else { Issue.record("x"); return }
    #expect(tool == "shell" && input["cmd"]?.string == "ls")
    #expect(p.decode(HookEnvelope(agent: "example-agent", event: "Unknown", payload: .object(["session_id": .string("s")]))) == nil)
}

@Test func manifestInstallAndUninstallRoundTrip() throws {
    let p = try exampleManifest()
    let original: JSONValue = .object(["theme": .string("dark")])
    let plan = try #require(p.installPlan(settings: original, retireCommandsContaining: []))
    #expect(plan.changed)
    #expect(plan.after["hooks"]?["BeforeTool"]?.array?.count == 1)
    #expect(p.installStatus(settings: plan.after).hooksInstalled)
    let back = try #require(p.uninstallPlan(settings: plan.after, previousStatusLine: nil))
    #expect(back.after == original)
}

@Test func manifestRejectsBadIDs() {
    #expect(throws: ManifestPlugin.LoadError.badID("Bad_ID")) {
        try ManifestPlugin.parse(.object(["id": .string("Bad_ID"), "name": .string("x")]))
    }
    #expect(throws: ManifestPlugin.LoadError.missingField("name")) {
        try ManifestPlugin.parse(.object(["id": .string("ok")]))
    }
}

@Test func jsonPathSupportsIndexes() {
    let v: JSONValue = .object(["a": .array([.object(["b": .string("hit")])])])
    #expect(ManifestPlugin.path("$.a[0].b", in: v)?.string == "hit")
    #expect(ManifestPlugin.path("$.a[1].b", in: v) == nil)
    #expect(ManifestPlugin.path("a.b", in: v) == nil)
}
