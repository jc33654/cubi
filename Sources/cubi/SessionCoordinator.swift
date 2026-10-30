import AppKit
import CubiKit

/// Glue between the socket server, the session store and the island: decodes envelopes, applies
/// them to the store, holds blocking requests until the user decides, and mirrors sessions onto robots.
@MainActor
final class SessionCoordinator {
    private(set) var store = SessionStore()
    private let island: IslandController
    let notifier = Notifier()
    let ignored = IgnoredDirectories()
    let registry = PluginRegistry()
    private var ignoredLogged: Set<String> = []
    private var server: HookServer?
    private var sleepTimer: Timer?
    private var watchTimer: Timer?
    private(set) var lastUsage: StatuslineInfo?
    /// Oldest first. At most one per session: Claude Code waits on each.
    private var pending: [PendingRequest] = []
    private var watchers: [UUID: TranscriptWatcher] = [:]
    /// Sessions whose question the user sent back to the terminal, with when. The permission-flow
    /// copy of the same question that follows must not open a new card.
    private var deferredQuestions: [String: Date] = [:]
    private static let deferGrace: TimeInterval = 60

    init(island: IslandController) {
        self.island = island
        island.state.onDecision = { [weak self] id, decision in self?.decide(id, decision) }
        island.state.onFocus = { [weak self] id in
            guard let info = self?.store.sessions[id] else { return }
            TerminalFocus.focus(info)
        }
        notifier.onActivate = { [weak self] id in
            guard let info = self?.store.sessions[id] else { return }
            TerminalFocus.focus(info)
        }
    }

    private static let usageKey = "lastUsage"

    func start() {
        RelayInstaller.ensureInstalled()
        // The status line only fires when a session changes; restore the last reading so the
        // readout is not blank until then.
        if let data = UserDefaults.standard.data(forKey: Self.usageKey) {
            do {
                let saved = try JSONDecoder().decode(StatuslineInfo.self, from: data)
                lastUsage = saved
                store.seedUsage(saved)
                sync()
                CubiLog.write("restored usage 5h=\(saved.fiveHour.map { "\(Int($0.usedPercent))%" } ?? "nil") 7d=\(saved.sevenDay.map { "\(Int($0.usedPercent))%" } ?? "nil")")
            } catch {
                CubiLog.write("saved usage unreadable: \(error)")
            }
        } else {
            CubiLog.write("no saved usage")
        }
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
        watchTimer?.invalidate()
    }

    // MARK: - Events

    private func handle(_ envelope: HookEnvelope, _ connection: HookConnection) {
        guard let plugin = registry.plugin(for: envelope.agent) else {
            if ignoredLogged.insert("agent:" + envelope.agent).inserted { CubiLog.write("no plugin for agent \(envelope.agent)") }
            connection.close()
            return
        }
        guard registry.isEnabled(plugin.id) else {
            connection.close()
            return
        }
        guard var decoded = plugin.decode(envelope) else {
            CubiLog.write("ignored \(envelope.agent)/\(envelope.event ?? "?")")
            connection.close()
            return
        }
        decoded.session.agent = plugin.id
        let sessionID = decoded.session.id

        if store.sessions[sessionID] == nil, ignored.ignores(decoded.session.cwd) {
            if ignoredLogged.insert(sessionID).inserted { CubiLog.write("ignored session \(sessionID.prefix(8)) in \(decoded.session.cwd ?? "?")") }
            connection.close()
            return
        }

        // A later event for the same tool call (or the turn moving on) means the terminal or Esc
        // settled the request.
        if let waiting = pending.first(where: { $0.sessionID == sessionID }), decoded.settlesPendingRequest(toolUseID: waiting.toolUseID) {
            CubiLog.write("request settled elsewhere (\(decoded.event.name)): session=\(sessionID.prefix(8))")
            withdraw(sessionID: sessionID, outcome: .handledElsewhere)
        }

        // A prompt the plugin cannot answer from the island (no reply template) goes back to the
        // agent's own UI at once: no card, no sound, the robot just shows the tool as running.
        if let needed = decoded.event.requiredCapability, !plugin.capabilities.contains(needed) {
            CubiLog.write("\(plugin.id) cannot answer \(decoded.event.name) here; left to the agent")
            connection.close()
            decoded.event = decoded.event.handedBackToAgent
        }

        switch decoded.event {
        case .permissionRequest(let tool, let input, let suggestions):
            if tool == "AskUserQuestion" {
                if let at = deferredQuestions[sessionID], Date().timeIntervalSince(at) < Self.deferGrace {
                    // The user asked for the terminal: let it have this one.
                    deferredQuestions.removeValue(forKey: sessionID)
                    connection.close()
                    return
                }
                guard let questions = AskQuestion.parse(input) else {
                    CubiLog.write("AskUserQuestion (permission) input not understood, leaving it to the terminal")
                    connection.close()
                    return
                }
                withdraw(sessionID: sessionID, outcome: .handledElsewhere)
                hold(PendingRequest(sessionID: sessionID, agent: plugin.id,
                                    kind: .question(questions: questions, raw: input, channel: .permissionRequest),
                                    envelope: envelope, connection: connection, toolUseID: toolUseID(decoded)),
                     transcript: decoded.session.transcriptPath)
            } else {
                withdraw(sessionID: sessionID, outcome: .handledElsewhere)
                hold(PendingRequest(sessionID: sessionID, agent: plugin.id, kind: .approval(tool: tool, input: input, suggestions: suggestions),
                                    envelope: envelope, connection: connection, toolUseID: toolUseID(decoded)),
                     transcript: decoded.session.transcriptPath)
            }
        case .question(let raw):
            guard let questions = AskQuestion.parse(raw) else {
                CubiLog.write("AskUserQuestion input not understood, leaving it to the terminal")
                connection.close()
                return
            }
            withdraw(sessionID: sessionID, outcome: .handledElsewhere)
            hold(PendingRequest(sessionID: sessionID, agent: plugin.id, kind: .question(questions: questions, raw: raw, channel: .preToolUse),
                                envelope: envelope, connection: connection, toolUseID: toolUseID(decoded)),
                 transcript: decoded.session.transcriptPath)
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

    /// PermissionRequest carries no tool_use_id; the PreToolUse just before it did.
    private func toolUseID(_ decoded: DecodedHook) -> String? {
        decoded.toolUseID ?? store.sessions[decoded.session.id]?.lastToolUseID
    }

    private func hold(_ request: PendingRequest, transcript: String?) {
        pending.append(request)
        CubiLog.write("holding \(request.isQuestion ? "question" : "approval") session=\(request.sessionID.prefix(8)) tool_use_id=\(request.toolUseID ?? "-")")
        if let w = TranscriptWatcher(path: transcript) { watchers[request.id] = w }
        startWatchingIfNeeded()
    }

    /// The relay went away before we answered: the user pressed Esc, answered in the terminal,
    /// or the relay's deadline passed. Either way the card is moot.
    private func clientClosed(_ connection: HookConnection) {
        guard let i = pending.firstIndex(where: { $0.connection === connection }) else { return }
        let request = pending.remove(at: i)
        watchers.removeValue(forKey: request.id)
        CubiLog.write("relay closed first: session=\(request.sessionID.prefix(8))")
        store.resolvePending(request.sessionID, outcome: .handledElsewhere)
        sync()
    }

    private func withdraw(sessionID: String, outcome: SessionStore.PendingOutcome) {
        guard let i = pending.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        let request = pending.remove(at: i)
        watchers.removeValue(forKey: request.id)
        request.connection.close()
        store.resolvePending(sessionID, outcome: outcome)
    }

    // MARK: - Transcript watching (terminal decisions that do not cancel the hook)

    private func startWatchingIfNeeded() {
        guard watchTimer == nil, !watchers.isEmpty else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTranscripts() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func pollTranscripts() {
        var settled: [String] = []
        for request in pending {
            guard var w = watchers[request.id] else { continue }
            if w.settled(toolUseID: request.toolUseID) { settled.append(request.sessionID) } else { watchers[request.id] = w }
        }
        for id in settled {
            CubiLog.write("transcript moved on: session=\(id.prefix(8))")
            withdraw(sessionID: id, outcome: .handledElsewhere)
        }
        if !settled.isEmpty { sync() }
        if watchers.isEmpty {
            watchTimer?.invalidate()
            watchTimer = nil
        }
    }

    // MARK: - Decisions from the island

    private func decide(_ id: UUID, _ decision: Decision) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: i)
        watchers.removeValue(forKey: request.id)
        let outcome: SessionStore.PendingOutcome
        let canonical: CanonicalReply?
        switch decision {
        case .allow: canonical = .allow
        case .always: canonical = .always
        case .deny: canonical = .deny(message: "Denied from Cubi")
        case .answers(let a): canonical = .answers(a)
        case .deferToTerminal: canonical = nil
        }
        if let canonical, let plugin = registry.plugin(for: request.agent),
           let line = plugin.reply(canonical, for: request.context) {
            request.connection.reply(line)
            switch canonical {
            case .allow, .always: outcome = .allowed
            case .deny: outcome = .denied
            case .answers: outcome = .answered
            }
        } else {
            if canonical == nil {
                CubiLog.write("deferred to terminal: session=\(request.sessionID.prefix(8))")
                // Only a PreToolUse question is followed by a PermissionRequest for the same
                // tool, which must then be left to the terminal as well.
                if case .question(_, _, .preToolUse) = request.kind { deferredQuestions[request.sessionID] = Date() }
            } else {
                CubiLog.write("plugin \(request.agent) has no reply for \(decision); leaving it to the agent")
            }
            request.connection.close()
            outcome = .handledElsewhere
        }
        CubiLog.write("decided \(outcome): session=\(request.sessionID.prefix(8))")
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
                        self.island.state.forgetLook(id)
                        self.sync()
                    }
                }
            case .notify(let session, let title, let body):
                notifier.notify(title: title, body: body, thread: session)
            case .usage(let info):
                // The cost moves every tick; only a rate-limit window is worth a log line and a save.
                if SessionStore.windowsChanged(from: lastUsage, to: info) {
                    CubiLog.write("usage 5h=\(info.fiveHour.map { "\(Int($0.usedPercent))%" } ?? "nil") 7d=\(info.sevenDay.map { "\(Int($0.usedPercent))%" } ?? "nil") ctx=\(info.contextPercent.map { "\(Int($0))%" } ?? "nil") name=\(info.sessionName ?? "-")")
                    if let data = try? JSONEncoder().encode(info) { UserDefaults.standard.set(data, forKey: Self.usageKey) }
                }
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
            let bot = existing.removeValue(forKey: info.id) ?? {
                let b = BotRuntime(id: info.id, name: info.name, color: SessionPalette.colors[info.colorIndex])
                b.apply(state.looks.look(for: info.id))
                return b
            }()
            if bot.name != info.name { bot.name = info.name }
            bot.ticker = info.ticker
            bot.stateLabel = info.botState.rawValue
            bot.model.waitingBadge = info.waitingBadge
            bot.model.contextPercent = info.contextPercent
            if bot.contextPercent != info.contextPercent { bot.contextPercent = info.contextPercent }
            if bot.modelName != info.model { bot.modelName = info.model }
            if bot.lastEdit != info.lastEdit { bot.lastEdit = info.lastEdit }
            if bot.agent != info.agent { bot.agent = info.agent }
            bot.model.setState(info.botState)
            bots.append(bot)
        }
        if let demo = existing["demo"] { bots.append(demo) }
        if bots.map(\.id) != state.bots.map(\.id) { state.bots = bots }
        if let shown = state.showingDiffFor, !bots.contains(where: { $0.id == shown }) { state.showingDiffFor = nil }
        if state.usage != lastUsage { state.usage = lastUsage }

        let cards = pending.map { card(for: $0) }
        if cards != state.pendingCards {
            state.pendingCards = cards
            if cards.isEmpty { state.expandedHeight = 190 }
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
}
