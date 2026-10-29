import AppKit
import CubiKit

/// Glue between the socket server, the session store and the island: decodes envelopes, applies
/// them to the store, holds blocking requests until the user decides, and mirrors sessions onto robots.
@MainActor
final class SessionCoordinator {
    private(set) var store = SessionStore()
    private let island: IslandController
    let notifier = Notifier()
    private var server: HookServer?
    private var sleepTimer: Timer?
    private(set) var lastUsage: StatuslineInfo?
    /// Oldest first. At most one per session: Claude Code waits on each.
    private var pending: [PendingRequest] = []

    init(island: IslandController) {
        self.island = island
        island.state.onDecision = { [weak self] id, decision in self?.decide(id, decision) }
    }

    func start() {
        RelayInstaller.ensureInstalled()
        let server = HookServer(
            handler: { [weak self] envelope, connection in self?.handle(envelope, connection) },
            onClientClosed: { [weak self] connection in self?.clientClosed(connection) })
        do {
            try server.start()
            self.server = server
            CubiLog.write("listening on \(server.socketPath)")
        } catch {
            CubiLog.write("hook server failed to start: \(error)")
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    func stop() {
        server?.stop()
        sleepTimer?.invalidate()
    }

    // MARK: - Events

    private func handle(_ envelope: HookEnvelope, _ connection: HookConnection) {
        guard let decoded = ClaudeCodeDecoder.decode(envelope) else {
            CubiLog.write("ignored \(envelope.agent)/\(envelope.event ?? "?")")
            connection.close()
            return
        }
        let sessionID = decoded.session.id

        switch decoded.event {
        case .permissionRequest(let tool, let input, let suggestions):
            if tool == "AskUserQuestion" {
                // The question reached the permission flow (the PreToolUse answer was not taken, or
                // came too late). Answer it here instead; the earlier card is replaced, not duplicated.
                guard let questions = AskQuestion.parse(input) else {
                    CubiLog.write("AskUserQuestion (permission) input not understood, leaving it to the terminal")
                    connection.close()
                    return
                }
                withdraw(sessionID: sessionID, outcome: .handledElsewhere)
                pending.append(PendingRequest(sessionID: sessionID,
                                              kind: .question(questions: questions, raw: input, channel: .permissionRequest),
                                              connection: connection))
            } else {
                // One outstanding request per session: a newer one replaces a stale one.
                withdraw(sessionID: sessionID, outcome: .handledElsewhere)
                pending.append(PendingRequest(sessionID: sessionID, kind: .approval(tool: tool, input: input, suggestions: suggestions),
                                              connection: connection))
            }
        case .question(let raw):
            guard let questions = AskQuestion.parse(raw) else {
                CubiLog.write("AskUserQuestion input not understood, leaving it to the terminal")
                connection.close()
                return
            }
            withdraw(sessionID: sessionID, outcome: .handledElsewhere)
            pending.append(PendingRequest(sessionID: sessionID, kind: .question(questions: questions, raw: raw, channel: .preToolUse),
                                          connection: connection))
        case .stop:
            connection.close()
        default:
            connection.close()
        }

        let effects = store.apply(decoded, now: Date().timeIntervalSinceReferenceDate)
        CubiLog.write("event \(decoded.event.name) session=\(sessionID.prefix(8)) pending=\(pending.count)")
        run(effects)
        sync()
        if decoded.event.isBlocking { Sounds.play(.pending) }
        if case .stop = decoded.event { Sounds.play(.done) }
    }

    /// The relay went away before we answered: the user pressed Esc, answered in the terminal,
    /// or the relay's deadline passed. Either way the card is moot.
    private func clientClosed(_ connection: HookConnection) {
        guard let i = pending.firstIndex(where: { $0.connection === connection }) else { return }
        let request = pending.remove(at: i)
        store.resolvePending(request.sessionID, outcome: .handledElsewhere)
        sync()
    }

    private func withdraw(sessionID: String, outcome: SessionStore.PendingOutcome) {
        guard let i = pending.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        let request = pending.remove(at: i)
        request.connection.close()
        store.resolvePending(sessionID, outcome: outcome)
    }

    // MARK: - Decisions from the island

    private func decide(_ id: UUID, _ decision: Decision) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: i)
        let outcome: SessionStore.PendingOutcome
        switch (request.kind, decision) {
        case (.approval, .allow):
            request.connection.reply(ClaudeCodeReplies.permission(.allow))
            outcome = .allowed
        case (.approval(_, _, let suggestions), .always):
            request.connection.reply(ClaudeCodeReplies.permission(.always(suggestions: suggestions)))
            outcome = .allowed
        case (.approval, .deny):
            request.connection.reply(ClaudeCodeReplies.permission(.deny(message: "Denied from Cubi")))
            outcome = .denied
        case (.question(_, let raw, let channel), .answers(let answers)):
            let questions = raw["questions"] ?? .array([])
            switch channel {
            case .preToolUse:
                request.connection.reply(ClaudeCodeReplies.question(questions: questions, answers: answers))
            case .permissionRequest:
                request.connection.reply(ClaudeCodeReplies.questionViaPermission(questions: questions, answers: answers))
            }
            outcome = .answered
        case (_, .deferToTerminal):
            CubiLog.write("deferred to terminal: session=\(request.sessionID.prefix(8))")
            request.connection.close()
            outcome = .handledElsewhere
        default:
            CubiLog.write("decision \(decision) does not fit request, closing without a decision")
            request.connection.close()
            outcome = .handledElsewhere
        }
        store.resolvePending(request.sessionID, outcome: outcome)
        sync()
        switch outcome {
        case .allowed: Sounds.play(.allow)
        case .denied: Sounds.play(.deny)
        case .answered: Sounds.play(.answer)
        case .handledElsewhere: break
        }
    }

    // MARK: - Effects and timers

    private func run(_ effects: [StoreEffect]) {
        for effect in effects {
            switch effect {
            case .added, .removed:
                break
            case .revertToIdle(let id, let after):
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.store.revertToIdle(id)
                        self?.sync()
                    }
                }
            case .removeLater(let id, let after):
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.store.sessions[id]?.ended == true else { return }
                        self.withdraw(sessionID: id, outcome: .handledElsewhere)
                        self.store.remove(id)
                        self.sync()
                    }
                }
            case .notify(let session, let title, let body):
                notifier.notify(title: title, body: body, thread: session)
            case .usage(let info):
                lastUsage = info
            }
        }
    }

    private func tick() {
        store.tick(now: Date().timeIntervalSinceReferenceDate)
        sync()
    }

    // MARK: - Mirror sessions and cards onto the island

    private func sync() {
        let state = island.state
        var existing = Dictionary(uniqueKeysWithValues: state.bots.map { ($0.id, $0) })
        var bots: [BotRuntime] = []
        for info in store.ordered {
            let bot = existing.removeValue(forKey: info.id)
                ?? BotRuntime(id: info.id, name: info.name, color: SessionPalette.colors[info.colorIndex])
            if bot.name != info.name { bot.name = info.name }
            bot.ticker = info.ticker
            bot.stateLabel = info.botState.rawValue
            bot.model.waitingBadge = info.waitingBadge
            bot.model.contextPercent = info.contextPercent
            bot.model.setState(info.botState)
            bots.append(bot)
        }
        if let demo = existing["demo"] { bots.append(demo) }
        if bots.map(\.id) != state.bots.map(\.id) { state.bots = bots }

        let cards = pending.map { card(for: $0) }
        if cards != state.pendingCards {
            state.pendingCards = cards
            state.expandedHeight = Self.expandedHeight(for: cards.first, compact: state.compactHeight)
        }

        let hold = !pending.isEmpty
        if hold != state.holdOpen {
            state.holdOpen = hold
            hold ? island.present() : island.releaseHold()
        } else if hold && state.mode != .expanded {
            island.present()
        }
    }

    private func card(for request: PendingRequest) -> PendingCard {
        let info = store.sessions[request.sessionID]
        let name = info?.name ?? SessionStore.defaultName(id: request.sessionID, cwd: nil)
        let color = SessionPalette.colors[info?.colorIndex ?? 0]
        switch request.kind {
        case .approval(let tool, let input, let suggestions):
            let summary = ApprovalSummary.describe(tool: tool, input: input)
            let canAlways = (suggestions.array?.isEmpty == false)
            return PendingCard(id: request.id, sessionName: name, color: color,
                               content: .approval(title: summary.title, detail: summary.detail, canAlways: canAlways))
        case .question(let questions, _, _):
            return PendingCard(id: request.id, sessionName: name, color: color, content: .question(questions))
        }
    }

    private static func expandedHeight(for card: PendingCard?, compact: CGFloat) -> CGFloat {
        guard let card else { return 190 }
        switch card.content {
        case .approval:
            return compact + 150
        case .question(let questions):
            let q = questions.first
            let options = CGFloat(q?.options.count ?? 1)
            let rows = options * 36 + (q?.multiSelect == true ? 34 : 0)
            return min(360, compact + 70 + rows)
        }
    }
}
