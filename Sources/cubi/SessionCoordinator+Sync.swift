import Foundation
import CubiKit

/// The coordinator's read side: mirror the store onto the island and keep the 放生 / 去睡覺 sets
/// across launches. No hook handling or decisions here; see SessionCoordinator.swift for those.
extension SessionCoordinator {
    // MARK: - Mirror sessions and cards onto the island

    func sync() {
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
            if bot.resting != info.resting { bot.resting = info.resting }
            if bot.cwd != info.cwd { bot.cwd = info.cwd }
            if bot.client != info.client { bot.client = info.client }
            if bot.startedAt != info.startedAt { bot.startedAt = info.startedAt }
            if bot.prompts != info.prompts { bot.prompts = info.prompts }
            if bot.toolCalls != info.toolCalls { bot.toolCalls = info.toolCalls }
            if bot.stats != info.stats { bot.stats = info.stats; bot.statsAt = Date() }
            if bot.costUSD != info.costUSD { bot.costUSD = info.costUSD }
            // Looked up once per path, again on a later sync if the file was not there yet.
            if bot.transcriptPath != info.transcriptPath || (bot.transcriptCreatedAt == nil && info.transcriptPath != nil) {
                bot.transcriptPath = info.transcriptPath
                bot.transcriptCreatedAt = info.transcriptPath.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0))?[.creationDate] as? Date
                }
            }
            bot.model.setState(info.botState)
            bots.append(bot)
        }
        if let demo = existing["demo"] { bots.append(demo) }
        if state.draggingBot != nil {
            // Mid-drag the island's order is the truth; the store catches up when the robot is dropped.
            let rank = Dictionary(state.bots.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            bots.sort { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
        }
        if bots.map(\.id) != state.bots.map(\.id) { state.bots = bots }
        state.pruneLooks(keeping: Set(bots.map(\.id)))
        if let shown = state.showingDiffFor, !bots.contains(where: { $0.id == shown }) { state.showingDiffFor = nil }
        if let sel = state.selectedSession, !bots.contains(where: { $0.id == sel }) { state.selectedSession = nil }
        if state.usage != lastUsage { state.usage = lastUsage }
        persistSets()

        let cards = pending.map { card(for: $0) }
        if cards != state.pendingCards { state.pendingCards = cards }

        let hold = !pending.isEmpty
        if hold != state.holdOpen {
            state.holdOpen = hold
            hold ? island.present() : island.releaseHold()
        } else if hold && state.mode != .expanded {
            island.present()
        }
    }

    // MARK: - 放生 / 去睡覺, the arrangement and the looks survive restarts

    static let dismissedKey = "dismissedSessions"
    static let restedKey = "restedSessions"
    static let orderKey = "sessionOrder"
    static let looksKey = "sessionLooks"
    static func loadSet(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func loadLooks() -> BotLooks {
        guard let data = UserDefaults.standard.data(forKey: looksKey) else { return BotLooks() }
        do { return try JSONDecoder().decode(BotLooks.self, from: data) } catch {
            CubiLog.write("saved looks unreadable, starting empty: \(error)")
            return BotLooks()
        }
    }

    func persistSets() {
        UserDefaults.standard.set(Array(store.dismissed), forKey: Self.dismissedKey)
        UserDefaults.standard.set(Array(store.manuallyRested), forKey: Self.restedKey)
        if store.preferredOrder != persistedOrder {
            persistedOrder = store.preferredOrder
            UserDefaults.standard.set(store.preferredOrder, forKey: Self.orderKey)
        }
        let looks = island.state.looks
        if looks != persistedLooks, let data = try? JSONEncoder().encode(looks) {
            persistedLooks = looks
            UserDefaults.standard.set(data, forKey: Self.looksKey)
        }
    }

    func card(for request: PendingRequest) -> PendingCard {
        let info = store.sessions[request.sessionID]
        let name = info?.name ?? SessionStore.defaultName(id: request.sessionID, cwd: nil)
        // The robot's colour, including one the user picked.
        let color = island.state.bots.first { $0.id == request.sessionID }?.color ?? SessionPalette.colors[info?.colorIndex ?? 0]
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
