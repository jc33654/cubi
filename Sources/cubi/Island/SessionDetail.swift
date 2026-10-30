import Foundation
import CubiKit

/// Text for the session info panel. Pure functions, so the panel stays a thin view.
@MainActor
enum SessionDetail {
    /// When the session began: the transcript file's birth time when Claude Code gave us one
    /// (survives Cubi restarts), else the first event Cubi saw; nil when neither is known (demo).
    static func start(_ bot: BotRuntime) -> (date: Date, approximate: Bool)? {
        if let created = bot.transcriptCreatedAt { return (created, false) }
        guard bot.startedAt > 0 else { return nil }
        return (Date(timeIntervalSinceReferenceDate: bot.startedAt), true)
    }

    /// Wall-clock time in the session: Claude Code's own figure (plus the time since it was
    /// reported, so the number keeps moving while the session idles), else since start.
    static func elapsed(_ bot: BotRuntime, now: Date) -> TimeInterval? {
        if let ms = bot.stats.totalDurationMS {
            return ms / 1000 + (bot.statsAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        }
        return start(bot).map { max(0, now.timeIntervalSince($0.date)) }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = UsageFormat.timeZone
        return c
    }()
    private static let clock = formatter("HH:mm")
    private static let dated = formatter("M/d HH:mm")
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = UsageFormat.timeZone
        f.dateFormat = format
        return f
    }

    /// Taipei time; the date only when it is not today.
    static func time(_ date: Date, now: Date = Date()) -> String {
        (calendar.isDate(date, inSameDayAs: now) ? clock : dated).string(from: date)
    }

    static func terminal(_ client: HookClient) -> String? {
        let program: String? = switch client.termProgram {
        case "apple_terminal": "Terminal"
        case "ghostty": "Ghostty"
        case "vscode": "VS Code"
        case let p?: p
        case nil: client.bundleID
        }
        guard let program else { return nil }
        return client.tty.map { "\(program) · \($0.replacingOccurrences(of: "/dev/", with: ""))" } ?? program
    }

    static func home(_ path: String) -> String { PathFormat.abbreviatingHome(path, home: CubiPaths.home.path) }
}
