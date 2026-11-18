import Foundation

/// 專注獎勵 (a pomodoro-like count): every 25 minutes the user's sessions were busy in
/// a day gives one (`gears`, the name it had first). Busy is a session's own stretches of activity (cut by
/// `SessionStore.workGap`), all sessions together counted once (their union), summed over the
/// day: a pause does not start the count again. Days are cut at local midnight and nothing
/// carries over. Sessions in Claude Code's restricted mode (the ones Cubi opens for an AI
/// estimate or a review) are Claude working alone, not counted.
///
/// What is kept is each day's merged busy spans, never the counts, so a count can always be
/// worked out again. Times are reference-date seconds, like the store's.
public struct FocusLog: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public struct Day: Equatable, Sendable {
        public var date: String
        public var seconds: Double
        public init(date: String, seconds: Double) {
            self.date = date
            self.seconds = seconds
        }
        public var gears: Int { Int(seconds / FocusLog.unit) }
        /// Until the next gear.
        public var untilNext: Double { FocusLog.unit - seconds.truncatingRemainder(dividingBy: FocusLog.unit) }
        /// "1h18m", "7m": the busy time, whole minutes.
        public var busyText: String { Self.text(seconds) }
        /// What the island says on hover: the day's busy time and what the next gear still needs.
        public var summary: String { "今天專注 \(busyText)，再 \(Self.text(untilNext.rounded(.up))) 下一個" }

        public static func text(_ seconds: Double) -> String {
            let minutes = Int(seconds / 60)
            return minutes >= 60 ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
        }
    }

    public static let unit = 25 * 60.0
    public static let keptDays = 90

    /// Local date ("2026-11-17") → that day's busy spans, merged and in order.
    public var days: [String: [Span]] = [:]

    public init(days: [String: [Span]] = [:]) {
        self.days = days
    }

    /// The busy spans of these sessions (closed stretches and the one still open), restricted
    /// sessions left out.
    public static func spans(of sessions: [SessionInfo]) -> [Span] {
        sessions.filter { $0.client.restricted != true }.flatMap { s in
            (s.segments + (s.openSegment.map { [$0] } ?? [])).map { Span(start: $0.start, end: $0.end) }
        }
    }

    /// Adds what was busy from `since` on (the moment counting was switched on: nothing before it
    /// is ever added), split into days; days older than `keptDays` before `now` go.
    public mutating func add(_ spans: [Span], since: Double, now: Double, calendar: Calendar = .current) {
        for span in spans {
            let start = max(span.start, since), end = min(span.end, now)
            guard end > start else { continue }
            for (date, piece) in Self.split(Span(start: start, end: end), calendar: calendar) {
                days[date] = Self.union((days[date] ?? []) + [piece])
            }
        }
        let oldest = calendar.date(byAdding: .day, value: -Self.keptDays, to: Date(timeIntervalSinceReferenceDate: now))
            .map { Self.dateKey($0.timeIntervalSinceReferenceDate, calendar: calendar) } ?? ""
        days = days.filter { $0.key >= oldest }
    }

    public func day(_ date: String) -> Day {
        Day(date: date, seconds: (days[date] ?? []).reduce(0) { $0 + $1.end - $1.start })
    }

    public func today(now: Double, calendar: Calendar = .current) -> Day {
        day(Self.dateKey(now, calendar: calendar))
    }

    /// The last `count` days up to `now`, newest first, days without anything included.
    public func recent(_ count: Int, now: Double, calendar: Calendar = .current) -> [Day] {
        let today = Date(timeIntervalSinceReferenceDate: now)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .map { day(Self.dateKey($0.timeIntervalSinceReferenceDate, calendar: calendar)) }
    }

    public static func dateKey(_ t: Double, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSinceReferenceDate: t))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A span cut at each local midnight it crosses.
    static func split(_ span: Span, calendar: Calendar) -> [(String, Span)] {
        var out: [(String, Span)] = []
        var start = span.start
        while start < span.end {
            let day = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: start))
            let next = calendar.date(byAdding: .day, value: 1, to: day)?.timeIntervalSinceReferenceDate ?? span.end
            let end = min(span.end, next)
            out.append((dateKey(start, calendar: calendar), Span(start: start, end: end)))
            start = end
        }
        return out
    }

    /// Overlapping or touching spans merged into one.
    static func union(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }
}
