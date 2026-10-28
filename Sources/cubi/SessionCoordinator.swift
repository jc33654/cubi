import AppKit
import CubiKit

/// Glue between the socket server, the session store and the island: decodes envelopes, applies
/// them to the store, runs the store's timers, and mirrors sessions onto robots.
@MainActor
final class SessionCoordinator {
    private(set) var store = SessionStore()
    private let island: IslandController
    let notifier = Notifier()
    private var server: HookServer?
    private var sleepTimer: Timer?
    private(set) var lastUsage: StatuslineInfo?

    init(island: IslandController) {
        self.island = island
    }

    func start() {
        RelayInstaller.ensureInstalled()
        let server = HookServer(
            handler: { [weak self] envelope, connection in self?.handle(envelope, connection) },
            onClientClosed: { [weak self] connection in self?.clientClosed(connection) })
        do {
            try server.start()
            self.server = server
            NSLog("cubi: listening on \(server.socketPath)")
        } catch {
            NSLog("cubi: hook server failed to start: \(error)")
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
            NSLog("cubi: ignored \(envelope.agent)/\(envelope.event ?? "?")")
            connection.close()
            return
        }
        // Phase 2 makes no decisions: closing at once hands the question back to the terminal
        // immediately instead of after the relay's timeout. Phase 3 holds these open.
        if decoded.event.isBlocking { connection.close() } else { connection.close() }

        let effects = store.apply(decoded, now: Date().timeIntervalSinceReferenceDate)
        run(effects)
        sync()
    }

    private func clientClosed(_ connection: HookConnection) {
        // Phase 3: a cancelled approval (answered in the terminal) withdraws its card here.
    }

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

    // MARK: - Mirror sessions onto robots

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
        // Keep the demo robot (if the menu created one) at the end.
        if let demo = existing["demo"] { bots.append(demo) }
        if bots.map(\.id) != state.bots.map(\.id) { state.bots = bots }

        let pending = store.anyPending
        if pending != state.holdOpen {
            state.holdOpen = pending
            pending ? island.reveal() : island.releaseHold()
        }
    }
}
