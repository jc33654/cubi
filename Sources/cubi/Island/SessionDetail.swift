import Foundation
import CubiKit

/// Text for the session info panel. Pure functions, so the panel stays a thin view.
@MainActor
enum SessionDetail {
    /// When the session began: the transcript file's birth time when Claude Code gave us one
    /// (survives Cubi restarts), else the first event Cubi saw.
    static func start(_ bot: BotRuntime) -> (date: Date, approximate: Bool) {
        if let created = bot.transcriptCreatedAt { return (created, false) }
        return (Date(timeIntervalSinceReferenceDate: bot.startedAt), true)
    }

    /// Wall-clock time in the session: Claude Code's own figure when present, else since start.
    static func elapsed(_ bot: BotRuntime, now: Date) -> TimeInterval {
        if let ms = bot.stats.totalDurationMS { return ms / 1000 }
        return max(0, now.timeIntervalSince(start(bot).date))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// Taipei time; the date only when it is not today.
    static func time(_ date: Date, now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = UsageFormat.timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = UsageFormat.timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
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

    static func home(_ path: String) -> String {
        let h = CubiPaths.home.path
        return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
    }
}
