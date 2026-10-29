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

    public enum Pending: Sendable, Equatable { case approval(tool: String), question }
}

/// Side effects the store cannot perform itself (timers, notifications, usage display).
public enum StoreEffect: Sendable, Equatable {
    case added(String)
    case removed(String)
    case revertToIdle(String, after: Double)
    case removeLater(String, after: Double)
    case notify(session: String, title: String, body: String)
    case usage(StatuslineInfo)
}

/// A reducer: feed it decoded hooks and a clock, read `sessions` back. No AppKit, fully testable.
public struct SessionStore: Sendable {
    public private(set) var sessions: [String: SessionInfo] = [:]
    /// Insertion order, so robots do not shuffle when a dictionary rehashes.
    public private(set) var order: [String] = []
    /// Account-wide rate limits, merged across sessions: every status line reports what its own
    /// session last heard from the API, so idle sessions carry stale or missing windows.
    public private(set) var usage: StatuslineInfo?

    public static let happyDuration = 1.5
    public static let endedLinger = 3.0
    public static let sleepAfter = 600.0

    public init() {}

    public var ordered: [SessionInfo] { order.compactMap { sessions[$0] } }

    /// Restore a reading saved by a previous run.
    public mutating func seedUsage(_ info: StatuslineInfo) { usage = info }

    /// A window from the most recently active session replaces what we have; from any other
    /// session it only fills a blank. Returns the merged reading when it changed.
    private mutating func mergeUsage(_ info: StatuslineInfo, from id: String) -> StatuslineInfo? {
        let newest = sessions.values.map(\.lastEventAt).max()
        let fresh = sessions[id].map { $0.lastEventAt >= (newest ?? 0) } ?? false
        func pick(_ new: UsageWindow?, over old: UsageWindow?) -> UsageWindow? {
            guard let new else { return old }
            return fresh || old == nil ? new : old
        }
        var merged = info
        merged.fiveHour = pick(info.fiveHour, over: usage?.fiveHour)
        merged.sevenDay = pick(info.sevenDay, over: usage?.sevenDay)
        guard merged != usage else { return nil }
        usage = merged
        return merged
    }
    public var anyPending: Bool { sessions.values.contains { $0.pending != nil } }

    // MARK: - Reduce

    public mutating func apply(_ hook: DecodedHook, now: Double) -> [StoreEffect] {
        var effects: [StoreEffect] = []
        let id = hook.session.id
        if sessions[id] == nil {
            switch hook.event {
            case .sessionEnd:
                return []
            case .statusline(let info):
                // The status line runs for every session, hooks or not; only hooked sessions get a
                // robot, but the account-wide usage is still useful.
                return mergeUsage(info, from: id).map { [.usage($0)] } ?? []
            default:
                sessions[id] = make(hook.session, now: now)
                order.append(id)
                effects.append(.added(id))
            }
        }
        var s = sessions[id]!
        s.lastEventAt = now
        s.ended = false
        if s.cwd == nil { s.cwd = hook.session.cwd }
        if s.client.tty == nil { s.client = hook.session.client }
        if let t = hook.session.transcriptPath { s.transcriptPath = t }
        if let id = hook.toolUseID { s.lastToolUseID = id }

        switch hook.event {
        case .sessionStart:
            s.botState = .idle
            s.pending = nil
            s.ticker = "準備好了"
        case .prompt(let text):
            s.botState = .thinking
            s.pending = nil
            s.ticker = text.split(separator: "\n").first.map(String.init) ?? text
        case .toolStart(let tool, let input):
            // The plain PreToolUse hook for AskUserQuestion carries no state of its own.
            guard tool != "AskUserQuestion" else { break }
            s.botState = .working
            s.pending = nil
            s.ticker = ClaudeCodeDecoder.toolLabel(tool: tool, input: input)
        case .toolEnd(let tool, let ok, let input, let response):
            s.pending = nil
            // The tool is done; Claude is composing what comes next.
            s.botState = ok ? .thinking : .error
            s.ticker = ok ? "思考中" : "失敗：" + ClaudeCodeDecoder.toolLabel(tool: tool, input: input)
            if ok, let edit = EditSummaryBuilder.build(tool: tool, input: input, response: response) {
                s.lastEdit = edit
                s.ticker = edit.label
            }
        case .permissionRequest(let tool, let input, _):
            s.botState = .waiting
            if tool == "AskUserQuestion" {
                s.pending = .question
                s.waitingBadge = .question
                s.ticker = "有問題要問你"
            } else {
                s.pending = .approval(tool: tool)
                s.waitingBadge = .exclaim
                s.ticker = "等你確認：" + ClaudeCodeDecoder.toolLabel(tool: tool, input: input)
            }
            effects.append(.notify(session: id, title: s.name, body: s.ticker))
        case .question(let q):
            s.botState = .waiting
            s.pending = .question
            s.waitingBadge = .question
            s.ticker = q["questions"]?.array?.first?["question"]?.string ?? "有問題要問你"
            effects.append(.notify(session: id, title: s.name, body: s.ticker))
        case .notification(let type, let message):
            switch type {
            case "permission_prompt":
                if s.pending == nil {
                    s.botState = .waiting
                    s.waitingBadge = .exclaim
                    s.pending = .approval(tool: "?")
                    s.ticker = "終端正在詢問"
                }
            case "idle_prompt":
                s.botState = .idle
                s.pending = nil
                s.ticker = "等你輸入"
                effects.append(.notify(session: id, title: s.name, body: message))
            default:
                break
            }
        case .stop:
            s.pending = nil
            s.botState = .happy
            s.ticker = "完成"
            effects.append(.revertToIdle(id, after: Self.happyDuration))
        case .sessionEnd:
            s.pending = nil
            s.ended = true
            s.botState = .sleeping
            s.ticker = "結束"
            effects.append(.removeLater(id, after: Self.endedLinger))
        case .subagentStart(let type):
            s.botState = .working
            s.ticker = "子代理：" + (type ?? "agent")
        case .subagentStop:
            s.botState = .working
        case .statusline(let info):
            if let n = info.sessionName, !n.isEmpty { s.name = n; s.explicitName = true }
            if let m = info.model { s.model = m }
            if let c = info.contextPercent {
                s.contextPercent = c
                if c >= 80, s.pending == nil, s.botState == .idle || s.botState == .tired { s.botState = .tired }
            }
            if let merged = mergeUsage(info, from: id) { effects.append(.usage(merged)) }
            // Status line runs constantly; it is not "activity" for the sleep timer.
            s.lastEventAt = sessions[id]!.lastEventAt
        }
        sessions[id] = s
        return effects
    }

    public enum PendingOutcome: Sendable, Equatable { case allowed, denied, answered, handledElsewhere }

    /// The blocking request for `id` is over, decided on the island or elsewhere.
    public mutating func resolvePending(_ id: String, outcome: PendingOutcome) {
        guard var s = sessions[id], s.pending != nil else { return }
        s.pending = nil
        switch outcome {
        case .allowed:
            s.botState = .working
            s.ticker = "已允許，執行中"
        case .denied:
            s.botState = .thinking
            s.ticker = "已拒絕"
        case .answered:
            s.botState = .thinking
            s.ticker = "已回答"
        case .handledElsewhere:
            // Esc, a terminal answer, or a timeout: nothing more may come for a while.
            s.botState = s.contextPercent >= 80 ? .tired : .idle
            s.ticker = "已在終端處理"
        }
        sessions[id] = s
    }

    /// Timer-driven transitions: happy → idle, sleeping after inactivity.
    public mutating func revertToIdle(_ id: String) {
        guard var s = sessions[id], s.botState == .happy else { return }
        s.botState = s.contextPercent >= 80 ? .tired : .idle
        sessions[id] = s
    }

    public mutating func tick(now: Double) {
        for (id, var s) in sessions where !s.ended && s.pending == nil {
            if now - s.lastEventAt >= Self.sleepAfter, s.botState == .idle || s.botState == .tired {
                s.botState = .sleeping
                sessions[id] = s
            }
        }
    }

    public mutating func remove(_ id: String) {
        sessions.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    // MARK: - Helpers

    private func make(_ ref: SessionRef, now: Double) -> SessionInfo {
        let taken = Set(sessions.values.map(\.colorIndex))
        return SessionInfo(id: ref.id, name: Self.defaultName(id: ref.id, cwd: ref.cwd), cwd: ref.cwd,
                           client: ref.client, transcriptPath: ref.transcriptPath, agent: ref.agent,
                           colorIndex: SessionPalette.index(for: ref.id, taken: taken), lastEventAt: now)
    }

    /// Same fallback chain as notify-hook.sh: session name, else cwd basename, else id prefix.
    public static func defaultName(id: String, cwd: String?) -> String {
        if let cwd, let last = cwd.split(separator: "/").last, !last.isEmpty { return String(last) }
        return String(id.prefix(8))
    }
}
