// One agent (Claude Code, Codex, …) = one plugin. A plugin maps its native hook payloads onto
// canonical events, turns the user's decisions back into the reply the agent expects, and knows
// how to install itself. It returns data and never calls back, so a manifest-driven plugin can
// implement the same protocol without code.

public struct AgentCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let approvals = AgentCapabilities(rawValue: 1)
    public static let questions = AgentCapabilities(rawValue: 2)
    public static let statusline = AgentCapabilities(rawValue: 4)
}

public struct SecretSpec: Sendable, Equatable {
    public var key: String
    public var label: String
    public var required: Bool
    public init(key: String, label: String, required: Bool) {
        self.key = key
        self.label = label
        self.required = required
    }
}

/// What the user decided on a card, agent-neutral.
public enum CanonicalReply: Sendable, Equatable {
    case allow
    case always
    case deny(message: String)
    case answers([String: String])
}

/// The request a reply answers: the original envelope plus what the card was about.
public struct PendingContext: Sendable {
    public enum Kind: Sendable { case approval, questionPreToolUse, questionPermission }
    public var kind: Kind
    public var envelope: HookEnvelope
    public init(kind: Kind, envelope: HookEnvelope) {
        self.kind = kind
        self.envelope = envelope
    }
}

/// How the plugin's hooks get into the agent's config. `jsonHooks` is the Claude Code shape
/// (an object with "hooks": {event: [groups]}); `manual` only shows the user what to paste.
public enum InstallMode: Sendable, Equatable {
    case jsonHooks(file: String)
    case manual(instructions: String)
}

public protocol AgentPlugin: Sendable {
    /// Matches `HookEnvelope.agent`, `^[a-z0-9-]{1,24}$`.
    var id: String { get }
    var displayName: String { get }
    var accentColor: RGB { get }
    var capabilities: AgentCapabilities { get }
    var secrets: [SecretSpec] { get }
    var installMode: InstallMode { get }
    /// True for a plugin shipped inside the app (cannot be removed, only disabled).
    var isBuiltIn: Bool { get }

    func decode(_ envelope: HookEnvelope) -> DecodedHook?
    /// The line the relay should print, or nil for "no decision".
    func reply(_ reply: CanonicalReply, for context: PendingContext) -> String?
    /// For `.jsonHooks`: the settings object after installing (and after removing).
    func installPlan(settings: JSONValue, retireCommandsContaining: [String]) -> ClaudeHookInstaller.Plan?
    func uninstallPlan(settings: JSONValue, previousStatusLine: JSONValue?) -> ClaudeHookInstaller.Plan?
    func installStatus(settings: JSONValue) -> ClaudeHookInstaller.Status
}

public extension AgentPlugin {
    var secrets: [SecretSpec] { [] }
    var isBuiltIn: Bool { false }
    func installPlan(settings: JSONValue, retireCommandsContaining: [String]) -> ClaudeHookInstaller.Plan? { nil }
    func uninstallPlan(settings: JSONValue, previousStatusLine: JSONValue?) -> ClaudeHookInstaller.Plan? { nil }
    func installStatus(settings: JSONValue) -> ClaudeHookInstaller.Status {
        ClaudeHookInstaller.Status(hooksInstalled: false, statuslineChained: false, legacyNotificationCommands: [])
    }
}

public enum AgentID {
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 24 && id.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }
}
