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
    /// Per-session details for the info panel; all optional, shown only when the agent sends them.
    public var session = SessionStats()

    public init(sessionName: String? = nil, model: String? = nil, contextPercent: Double? = nil,
                fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil, costUSD: Double? = nil,
                session: SessionStats = SessionStats()) {
        self.sessionName = sessionName
        self.model = model
        self.contextPercent = contextPercent
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.costUSD = costUSD
        self.session = session
    }

    /// Readings saved by older builds lack newer keys: every field decodes as optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        contextPercent = try c.decodeIfPresent(Double.self, forKey: .contextPercent)
        fiveHour = try c.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        session = try c.decodeIfPresent(SessionStats.self, forKey: .session) ?? SessionStats()
    }
}

/// What a status line says about its own session (Claude Code's `workspace`, `cost`, `model`…).
public struct SessionStats: Sendable, Equatable, Codable {
    public var modelDisplayName: String?
    public var projectDir: String?
    public var currentDir: String?
    public var version: String?
    public var effort: String?
    public var totalDurationMS: Double?
    public var apiDurationMS: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?

    public init(modelDisplayName: String? = nil, projectDir: String? = nil, currentDir: String? = nil, version: String? = nil,
                effort: String? = nil, totalDurationMS: Double? = nil, apiDurationMS: Double? = nil,
                linesAdded: Int? = nil, linesRemoved: Int? = nil) {
        self.modelDisplayName = modelDisplayName
        self.projectDir = projectDir
        self.currentDir = currentDir
        self.version = version
        self.effort = effort
        self.totalDurationMS = totalDurationMS
        self.apiDurationMS = apiDurationMS
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }

    /// Fields the newer reading has replace the older ones; nothing is ever blanked.
    public mutating func merge(_ newer: SessionStats) {
        modelDisplayName = newer.modelDisplayName ?? modelDisplayName
        projectDir = newer.projectDir ?? projectDir
        currentDir = newer.currentDir ?? currentDir
        version = newer.version ?? version
        effort = newer.effort ?? effort
        totalDurationMS = newer.totalDurationMS ?? totalDurationMS
        apiDurationMS = newer.apiDurationMS ?? apiDurationMS
        linesAdded = newer.linesAdded ?? linesAdded
        linesRemoved = newer.linesRemoved ?? linesRemoved
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

    /// The plugin capability a blocking event needs before the island may hold it.
    public var requiredCapability: AgentCapabilities? {
        switch self {
        case .permissionRequest(let tool, _, _): return tool == "AskUserQuestion" ? .questions : .approvals
        case .question: return .questions
        default: return nil
        }
    }

    /// The same moment seen as plain tool activity: what a session shows while a prompt the
    /// island cannot answer is handled by the agent's own UI.
    public var handedBackToAgent: CanonicalEvent {
        switch self {
        case .permissionRequest(let tool, let input, _): return .toolStart(tool: tool, input: input)
        case .question(let raw): return .toolStart(tool: "AskUserQuestion", input: raw)
        default: return self
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
    /// Set when a subagent, not the main agent, produced the hook.
    public var agentID: String?

    public init(session: SessionRef, event: CanonicalEvent, toolUseID: String? = nil, agentID: String? = nil) {
        self.session = session
        self.event = event
        self.toolUseID = toolUseID
        self.agentID = agentID
    }

    /// True when this hook proves the request waiting on the island (for the tool call
    /// `pendingToolUseID`) is over: the user answered in the terminal, pressed Esc, or the request
    /// timed out. Tool traffic only counts for the same tool call: parallel tool calls and
    /// subagents share the session id but say nothing about the request still waiting.
    public func settlesPendingRequest(toolUseID pending: String?) -> Bool {
        if agentID != nil { return false }
        let sameCall = pending == nil || toolUseID == nil || toolUseID == pending
        switch event {
        case .stop, .prompt, .sessionEnd: return true
        case .toolEnd: return sameCall
        case .toolStart(let tool, _): return tool != "AskUserQuestion" && sameCall
        default: return false
        }
    }
}
