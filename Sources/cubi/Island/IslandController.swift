import AppKit
import SwiftUI
import CubiKit

/// Owns the panel and the island state: pointer polling, open/close timing, screen changes.
@MainActor
final class IslandController {
    let state: IslandState
    private let panel = IslandPanel()
    private var pollTimer: Timer?
    private var closeWork: DispatchWorkItem?
    private var pointerInside = false
    private var screenObserver: NSObjectProtocol?
    private var demoBot: BotRuntime?

    init() {
        let screen = NotchGeometry.preferredScreen()
        let geometry = screen.map(NotchGeometry.measure) ?? NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), hasNotch: false,
            notchWidth: NotchGeometry.barWidth, notchHeight: NotchGeometry.barHeight)
        state = IslandState(geometry: geometry)

        let root = IslandRootView(state: state) { [weak self] in self?.tapped() }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: IslandPanel.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.pin(to: geometry)
        panel.orderFrontRegardless()
        if state.pinned { state.mode = .compact }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        }
        startPolling(interval: 0.125)
    }

    func shutdown() {
        pollTimer?.invalidate()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Geometry

    private func relocate() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry.measure(screen)
        guard geometry != state.geometry else { return }
        state.geometry = geometry
        panel.pin(to: geometry)
    }

    /// The island's rectangle in screen coordinates for the current mode.
    private func islandRect() -> CGRect {
        let size = state.size(for: state.mode)
        let f = state.geometry.screenFrame
        return CGRect(x: f.midX - size.width / 2 + state.xOffset(for: state.mode), y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: - Pointer polling

    private func startPolling(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        let mouse = NSEvent.mouseLocation
        let rect = islandRect()
        // On a notched screen the resting island is the notch itself, so a little padding helps
        // the pointer "find" it; elsewhere padding would steal clicks from the menu bar.
        let hover = state.geometry.hasNotch && state.mode != .expanded ? rect.insetBy(dx: -6, dy: -6) : rect
        let inside = hover.contains(mouse)

        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if inside != pointerInside {
            pointerInside = inside
            inside ? pointerEntered() : pointerLeft()
        }

        if !state.bots.isEmpty { updateLook(mouse: mouse, rect: rect) }

        // Poll faster near the island, slower far away: the timer is the only thing running when idle.
        let near = rect.insetBy(dx: -200, dy: -160).contains(mouse)
        let wanted: TimeInterval = state.mode == .expanded || inside ? 1.0 / 60 : (near ? 1.0 / 20 : 1.0 / 8)
        if let t = pollTimer, abs(t.timeInterval - wanted) > 0.001 { startPolling(interval: wanted) }
    }

    private func updateLook(mouse: CGPoint, rect: CGRect) {
        let dx = (mouse.x - rect.midX) / 260
        let dy = (mouse.y - rect.midY) / 200
        let lx = tanh(dx), ly = tanh(dy)
        for bot in state.bots { bot.model.setMouseLook(x: lx, y: ly) }
    }

    private func pointerEntered() {
        closeWork?.cancel()
        closeWork = nil
        switch state.mode {
        case .hidden: setMode(.compact)
        // Pinned: compact is the resting state, so hovering goes straight to the full view.
        case .compact where state.pinned: setMode(.expanded)
        default: break
        }
    }

    private func pointerLeft() {
        scheduleClose(after: state.mode == .expanded ? 1.5 : 0.6)
    }

    private func scheduleClose(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.pointerInside, !self.state.holdOpen else { return }
                CubiLog.write("island auto-close after \(delay)s")
                self.setMode(self.state.restingMode)
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setMode(_ mode: IslandMode) {
        guard state.mode != mode else { return }
        CubiLog.write("island \(state.mode) → \(mode) (hold=\(state.holdOpen) pinned=\(state.pinned) pointerInside=\(pointerInside))")
        state.mode = mode
    }

    private func tapped() {
        // With a card showing, taps belong to its buttons; the island stays expanded.
        if state.mode == .expanded && !state.pendingCards.isEmpty { return }
        setMode(state.mode == .expanded ? .compact : .expanded)
    }

    // MARK: - Menu actions

    var contextMenu: NSMenu? {
        get { panel.contextMenu }
        set { panel.contextMenu = newValue }
    }

    /// Opens the island for a few seconds, e.g. when the app is launched a second time.
    func showBriefly() {
        if state.mode == .hidden { setMode(.compact) }
        scheduleClose(after: 4)
    }

    /// A card needs an answer: go straight to the full view.
    func present() {
        closeWork?.cancel()
        closeWork = nil
        setMode(.expanded)
    }

    /// Nothing pending any more: close soon unless the pointer is on the island.
    func releaseHold() {
        if !pointerInside { scheduleClose(after: 1.5) }
    }

    func toggleFromMenu() {
        if state.mode == .hidden {
            setMode(.compact)
            scheduleClose(after: 4)
        } else {
            setMode(state.restingMode)
        }
    }

    func setPinned(_ on: Bool) {
        state.pinned = on
        closeWork?.cancel()
        closeWork = nil
        if on {
            if state.mode == .hidden { setMode(.compact) }
        } else if !pointerInside && !state.holdOpen {
            scheduleClose(after: 1)
        }
    }

    func addDemoBot() {
        guard demoBot == nil else { return }
        let id = "demo"
        let bot = BotRuntime(id: id, name: "demo", color: SessionPalette.color(for: id))
        bot.ticker = "示範用，不是真的 session"
        demoBot = bot
        state.bots.append(bot)
    }

    func removeDemoBot() {
        state.bots.removeAll { $0.id == "demo" }
        demoBot = nil
    }

    func setDemoState(_ s: BotState) {
        addDemoBot()
        demoBot?.model.setState(s)
        demoBot?.stateLabel = s.rawValue
        if s == .tired { demoBot?.model.contextPercent = 92 }
        if state.mode == .hidden {
            setMode(.compact)
            scheduleClose(after: 4)
        }
    }
}
