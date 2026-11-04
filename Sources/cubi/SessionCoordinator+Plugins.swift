import Foundation
import CubiKit

/// What tool plugins get to see of the sessions.
extension SessionCoordinator {
    func sessionInput(for id: String) -> PluginIO.SessionInput? {
        store.sessions[id].map { Self.input(for: $0) }
    }

    /// Every session the store has (ended ones linger a few seconds), plus the ones that were
    /// removed since the last tick, so their final stretch is reported once.
    func tickInput(now: Date = Date()) -> PluginIO.TickInput {
        let retired = retiredForPlugins
        retiredForPlugins = []
        // Two days of stretches is plenty for a minute-by-minute tick, and keeps the stdin small.
        let since = now.timeIntervalSinceReferenceDate - Self.tickWindow
        return PluginIO.TickInput(now: now.timeIntervalSince1970, sessions: store.ordered.map { Self.input(for: $0, since: since) } + retired)
    }

    static let tickWindow: Double = 48 * 3600

    /// The session is about to leave the store: close its stretch now and keep it for the next tick.
    func retireForPlugins(_ info: SessionInfo) {
        var s = info
        s.closeSegment(at: s.lastEventAt)
        guard !s.segments.isEmpty else { return }
        retiredForPlugins.removeAll { $0.id == s.id }
        retiredForPlugins.append(Self.input(for: s))
    }

    /// `since` (reference-date seconds) drops closed stretches that ended before it.
    static func input(for s: SessionInfo, since: Double = -.infinity) -> PluginIO.SessionInput {
        PluginIO.SessionInput(id: s.id, name: s.name, cwd: s.cwd, projectDirectory: s.projectDirectory, agent: s.agent,
                              segments: segments(of: s, since: since))
    }

    /// The store's clock is reference-date seconds; plugins get epoch seconds, whole.
    static func segments(of s: SessionInfo, since: Double) -> [PluginIO.Segment] {
        func epoch(_ t: Double) -> Double { (t + Date.timeIntervalBetween1970AndReferenceDate).rounded() }
        var list = s.segments.filter { $0.end >= since }.map { PluginIO.Segment(start: epoch($0.start), end: epoch($0.end), open: false) }
        if let open = s.openSegment { list.append(PluginIO.Segment(start: epoch(open.start), end: epoch(open.end), open: true)) }
        return list
    }
}
