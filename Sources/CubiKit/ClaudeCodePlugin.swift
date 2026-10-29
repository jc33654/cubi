/// The built-in first plugin: everything Cubi knows about Claude Code, behind the protocol.
public struct ClaudeCodePlugin: AgentPlugin {
    public static let agentID = "claude-code"

    public init() {}

    public var id: String { Self.agentID }
    public var displayName: String { "Claude Code" }
    public var accentColor: RGB { RGB(hex: 0xD97757) }
    public var capabilities: AgentCapabilities { [.approvals, .questions, .statusline] }
    public var installMode: InstallMode { .jsonHooks(file: "~/.claude/settings.json") }
    public var isBuiltIn: Bool { true }

    public func decode(_ envelope: HookEnvelope) -> DecodedHook? {
        ClaudeCodeDecoder.decode(envelope)
    }

    public func reply(_ reply: CanonicalReply, for context: PendingContext) -> String? {
        let payload = context.envelope.payload
        switch (context.kind, reply) {
        case (.approval, .allow):
            return ClaudeCodeReplies.permission(.allow)
        case (.approval, .always):
            return ClaudeCodeReplies.permission(.always(suggestions: payload["permission_suggestions"] ?? .null))
        case (.approval, .deny(let message)):
            return ClaudeCodeReplies.permission(.deny(message: message))
        case (.questionPreToolUse, .answers(let answers)):
            return ClaudeCodeReplies.question(questions: payload["tool_input"]?["questions"] ?? .array([]), answers: answers)
        case (.questionPermission, .answers(let answers)):
            return ClaudeCodeReplies.questionViaPermission(questions: payload["tool_input"]?["questions"] ?? .array([]), answers: answers)
        default:
            return nil
        }
    }

    public func installPlan(settings: JSONValue, retireCommandsContaining: [String]) -> ClaudeHookInstaller.Plan? {
        ClaudeHookInstaller.installPlan(settings: settings, retireCommandsContaining: retireCommandsContaining)
    }

    public func uninstallPlan(settings: JSONValue, previousStatusLine: JSONValue?) -> ClaudeHookInstaller.Plan? {
        ClaudeHookInstaller.uninstallPlan(settings: settings, previousStatusLine: previousStatusLine)
    }

    public func installStatus(settings: JSONValue) -> ClaudeHookInstaller.Status {
        ClaudeHookInstaller.status(settings)
    }
}
