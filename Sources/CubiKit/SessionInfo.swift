import Foundation

/// What the UI needs to know about one session.
public struct SessionInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var explicitName = false
    public var cwd: String?
    public var client: HookClient
    public var transcriptPath: String?
    public var agent = "claude-code"
    /// The most recent tool call id seen for the session (PermissionRequest itself carries none).
    public var lastToolUseID: String?
    public var colorIndex: Int
    public var botState: BotState = .idle
    public var waitingBadge: Badge = .exclaim
    public var ticker = ""
    public var lastEventAt: Double
    public var contextPercent: Double = 0
    public var model: String?
    public var pending: Pending? = nil
    public var ended = false
    /// The most recent Edit/Write, for the diff card.
    public var lastEdit: EditSummary? = nil
    /// When Cubi first saw the session (reference-date seconds, same clock as `lastEventAt`).
    public var startedAt: Double = 0
    /// Turns and tool calls seen by Cubi (not the session's whole history).
    public var prompts = 0
    public var toolCalls = 0
    /// What the status line reports about this session.
    public var stats = SessionStats()
    /// Where a new session for the same project should start: the project root when the status
    /// line told us, else the hooks' cwd.
    public var projectDirectory: String? { stats.projectDir ?? cwd }
    public var costUSD: Double? = nil
    /// Parked in the "晚安" zone: automatically after half a day, or by hand.
    public var rest: Rest = .none

    public enum Rest: Sendable, Equatable { case none, auto, manual }
    public var resting: Bool { rest != .none }

    public enum Pending: Sendable, Equatable { case approval(tool: String), question }

    /// Stretches of hook activity, closed when the session fell silent for `sleepAfter`; the
    /// stretch still running starts at `segmentStart` and reaches `lastEventAt`. What plugins
    /// turn into worked hours and calendar events.
    public var segments: [ActivitySegment] = []
    public var segmentStart: Double? = nil
    public var openSegment: ActivitySegment? { segmentStart.map { ActivitySegment(start: $0, end: lastEventAt) } }

    mutating func noteActivity(now: Double, gap: Double) {
        guard let start = segmentStart else { segmentStart = now; return }
        if now - lastEventAt >= gap {
            closeSegment(at: lastEventAt)
            segmentStart = now
        } else if now < start {
            segmentStart = now
        }
    }

    mutating func closeSegment(at end: Double) {
        if let start = segmentStart, end > start { segments.append(ActivitySegment(start: start, end: end)) }
        segmentStart = nil
    }
}

/// Reference-date seconds, like `SessionInfo.lastEventAt`.
public struct ActivitySegment: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
}

/// Side effects the store cannot perform itself (timers, notifications, usage display).
public enum StoreEffect: Sendable, Equatable {
    case revertToIdle(String, after: Double)
    case removeLater(String, after: Double)
    case notify(session: String, title: String, body: String)
    case usage(StatuslineInfo)
}
