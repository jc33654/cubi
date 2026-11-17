import Foundation
import Observation
import CubiKit

/// 專注零件 on this Mac: the switch (off until the user turns it on), when it was turned on (nothing
/// before that is counted, not even after a restart), and the busy spans per day (FocusLog), all in
/// the app's defaults. Never sent anywhere; nothing to do with the sprint plugin's hours.
@MainActor
@Observable
final class FocusRecorder {
    static let enabledKey = "focusEnabled"
    static let sinceKey = "focusSince"
    static let logKey = "focusLog"

    var enabled: Bool = UserDefaults.standard.bool(forKey: FocusRecorder.enabledKey) {
        didSet {
            guard enabled != oldValue else { return }
            // From this moment on: the time it was off is never filled in.
            if enabled { since = Date().timeIntervalSinceReferenceDate }
            if persists {
                UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
                UserDefaults.standard.set(since, forKey: Self.sinceKey)
                CubiLog.write("focus \(enabled ? "on" : "off")")
            }
            onChange()
        }
    }
    /// Off for offline renders: shown, never written.
    @ObservationIgnored var persists = true
    private(set) var since: Double = UserDefaults.standard.double(forKey: FocusRecorder.sinceKey)
    private(set) var log: FocusLog = FocusRecorder.savedLog()
    @ObservationIgnored var onChange: () -> Void = {}

    /// For `--render-settings` and `--render-island`: these days, switched on, nothing saved.
    static func preview(_ log: FocusLog) -> FocusRecorder {
        let r = FocusRecorder()
        r.persists = false
        r.enabled = true
        r.log = log
        return r
    }

    private static func savedLog() -> FocusLog {
        guard let data = UserDefaults.standard.data(forKey: logKey) else { return FocusLog() }
        do { return try JSONDecoder().decode(FocusLog.self, from: data) } catch {
            CubiLog.write("focus log unreadable, starting empty: \(error)")
            return FocusLog()
        }
    }

    /// Once a minute (and on the way out): what the sessions were busy with, added to the days.
    func record(_ sessions: [SessionInfo], now: Double = Date().timeIntervalSinceReferenceDate) {
        guard enabled else { return }
        var next = log
        next.add(FocusLog.spans(of: sessions), since: since, now: now)
        guard next != log else { return }
        log = next
        guard persists else { return }
        do { UserDefaults.standard.set(try JSONEncoder().encode(log), forKey: Self.logKey) } catch {
            CubiLog.write("focus log not saved: \(error)")
        }
    }

    /// What the island shows; nil while switched off.
    func today(now: Double = Date().timeIntervalSinceReferenceDate) -> FocusLog.Day? {
        enabled ? log.today(now: now) : nil
    }
}

extension FocusLog {
    /// Made-up days for offline renders: today and the twelve days before it, some empty, one of 10+.
    static func sample(now: Double = Date().timeIntervalSinceReferenceDate) -> FocusLog {
        var log = FocusLog()
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: now)).timeIntervalSinceReferenceDate + 9 * 3600
        for (daysAgo, minutes) in [(0, 78.0), (1, 140), (2, 0), (3, 265), (4, 30), (5, 0), (6, 0), (7, 95), (8, 24), (9, 50), (10, 180), (11, 0), (12, 60)] {
            let s = start - Double(daysAgo) * 86400
            if minutes > 0 { log.add([Span(start: s, end: s + minutes * 60)], since: 0, now: now) }
        }
        return log
    }
}
