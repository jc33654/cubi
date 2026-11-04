import Foundation
import CubiKit

/// What tool plugins get to see of the sessions.
extension SessionCoordinator {
    func sessionInput(for id: String) -> PluginIO.SessionInput? {
        store.sessions[id].map(Self.input(for:))
    }

    /// Every live session, for a plugin's `tick`.
    func tickInput(now: Date = Date()) -> PluginIO.TickInput {
        PluginIO.TickInput(now: now.timeIntervalSince1970, sessions: store.ordered.filter { !$0.ended }.map(Self.input(for:)))
    }

    static func input(for s: SessionInfo) -> PluginIO.SessionInput {
        PluginIO.SessionInput(id: s.id, name: s.name, cwd: s.cwd, projectDirectory: s.projectDirectory, agent: s.agent,
                              segments: segments(of: s))
    }

    /// The store's clock is reference-date seconds; plugins get epoch seconds, whole.
    static func segments(of s: SessionInfo) -> [PluginIO.Segment] {
        func epoch(_ t: Double) -> Double { (t + Date.timeIntervalBetween1970AndReferenceDate).rounded() }
        var list = s.segments.map { PluginIO.Segment(start: epoch($0.start), end: epoch($0.end), open: false) }
        if let open = s.openSegment { list.append(PluginIO.Segment(start: epoch(open.start), end: epoch(open.end), open: true)) }
        return list
    }
}
