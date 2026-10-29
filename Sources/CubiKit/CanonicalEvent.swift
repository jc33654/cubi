// Agent-neutral events. Each AgentPlugin maps its native hook payloads onto these; the session
// store and the UI never see agent-specific names.

public struct SessionRef: Sendable, Equatable {
    public var id: String
    public var cwd: String?
    public var client: HookClient
    /// Claude Code's own JSONL transcript for the session, when the payload names it.
    public var transcriptPath: String?
    /// Which plugin produced this session's events.
    public var agent: String = "claude-code"

    public init(id: String, cwd: String?, client: HookClient, transcriptPath: String? = nil, agent: String = "claude-code") {
        self.id = id
        self.cwd = cwd
        self.client = client
        self.transcriptPath = transcriptPath
        self.agent = agent
    }
}

public struct UsageWindow: Sendable, Equatable, Codable {
    public var usedPercent: Double
    /// Unix epoch seconds.
    public var resetsAt: Double?

    public init(usedPercent: Double, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct StatuslineInfo: Sendable, Equatable, Codable {
    public var sessionName: String?
    public var model: String?
    public var contextPercent: Double?
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var costUSD: Double?

    public init(sessionName: String? = nil, model: String? = nil, contextPercent: Double? = nil,
                fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil, costUSD: Double? = nil) {
        self.sessionName = sessionName
        self.model = model
        self.contextPercent = contextPercent
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.costUSD = costUSD
    }
}

public enum CanonicalEvent: Sendable, Equatable {
    case sessionStart(source: String?)
    case prompt(String)
    case toolStart(tool: String, input: JSONValue)
    case toolEnd(tool: String, ok: Bool, input: JSONValue, response: JSONValue)
    /// The agent is blocked until the user decides. `tool == "AskUserQuestion"` means the terminal
    /// is asking a question through the permission flow; treat it as a question, not an approval.
    case permissionRequest(tool: String, input: JSONValue, suggestions: JSONValue)
    case question(JSONValue)
    case notification(type: String, message: String)
    case stop(lastMessage: String?)
    case sessionEnd(reason: String?)
    case subagentStart(type: String?)
    case subagentStop(type: String?)
    case statusline(StatuslineInfo)

    /// Short name for logs.
    public var name: String {
        switch self {
        case .sessionStart: return "sessionStart"
        case .prompt: return "prompt"
        case .toolStart(let t, _): return "toolStart(\(t))"
        case .toolEnd(let t, let ok, _, _): return "toolEnd(\(t),\(ok ? "ok" : "failed"))"
        case .permissionRequest(let t, _, _): return "permissionRequest(\(t))"
        case .question: return "question"
        case .notification(let t, _): return "notification(\(t))"
        case .stop: return "stop"
        case .sessionEnd: return "sessionEnd"
        case .subagentStart: return "subagentStart"
        case .subagentStop: return "subagentStop"
        case .statusline: return "statusline"
        }
    }

    /// True when this event proves the session has moved past any request still waiting on
    /// the island (the user answered in the terminal, pressed Esc, or the request timed out).
    public var endsPendingRequest: Bool {
        switch self {
        case .toolEnd, .stop, .prompt, .sessionEnd, .subagentStart, .subagentStop: return true
        case .toolStart(let tool, _): return tool != "AskUserQuestion"
        default: return false
        }
    }

    /// True when the relay holds its connection open for a reply.
    public var isBlocking: Bool {
        switch self {
        case .permissionRequest, .question: return true
        default: return false
        }
    }
}

public struct DecodedHook: Sendable, Equatable {
    public var session: SessionRef
    public var event: CanonicalEvent
    /// Claude Code's id for the tool call this hook is about (PreToolUse/PostToolUse carry it).
    public var toolUseID: String?

    public init(session: SessionRef, event: CanonicalEvent, toolUseID: String? = nil) {
        self.session = session
        self.event = event
        self.toolUseID = toolUseID
    }
}
