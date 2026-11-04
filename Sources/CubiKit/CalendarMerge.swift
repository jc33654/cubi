import Foundation

/// How a plugin's calendar entry lands among the events already there. Pure: the app fetches the
/// nearby events and carries out the plan.
///
/// Every event Cubi writes carries a last line `由 Cubi 記錄 · <marker> <marker>…`; a marker seen
/// again is skipped, and an entry touching (within `gap`) an event of the same title that Cubi
/// wrote extends that event instead of starting another. Foreign events are never touched.
public enum CalendarMerge {
    public static let gap: Double = 5 * 60
    public static let minDuration: Double = 60
    public static let markerLinePrefix = "由 Cubi 記錄 · "

    public struct Existing: Sendable, Equatable {
        public var id: String
        public var title: String
        public var start: Double
        public var end: Double
        public var notes: String?

        public init(id: String, title: String, start: Double, end: Double, notes: String?) {
            self.id = id; self.title = title; self.start = start; self.end = end; self.notes = notes
        }
    }

    public enum Plan: Sendable, Equatable {
        case skip(String)
        case create(title: String, start: Double, end: Double, notes: String)
        /// Grow `id` to cover the entry (and any other adjacent events, which are removed).
        case extend(id: String, start: Double, end: Double, notes: String, remove: [String])
    }

    public static func plan(_ e: PluginIO.CalendarEntry, nearby: [Existing]) -> Plan {
        guard e.end - e.start >= minDuration else { return .skip("不到 1 分鐘") }
        // Seen before: a stretch still running is reported again with a later end, so the same
        // marker means "update". It may now touch other events of ours; those fold in too.
        if let same = nearby.first(where: { markers(in: $0.notes).contains(e.marker) }) {
            let start = min(same.start, e.start), end = max(same.end, e.end)
            // Neighbours are looked up by the event's own title: the entry's may have changed
            // (another ticket got bound) and the event keeps the title it was written with.
            let others = ours(same.title, in: nearby, start: start, end: end).filter { $0.id != same.id }
            guard e.start < same.start || e.end > same.end || !others.isEmpty else { return .skip("已寫過") }
            let all = [same] + others
            return .extend(id: same.id, start: min(start, all.map(\.start).min()!), end: max(end, all.map(\.end).max()!),
                           notes: notes(body: body(of: all, plus: e.notes), markers: all.flatMap { markers(in: $0.notes) }),
                           remove: others.map(\.id))
        }
        let adjacent = ours(e.title, in: nearby, start: e.start, end: e.end)
        let notes = notes(body: body(of: adjacent, plus: e.notes), markers: adjacent.flatMap { markers(in: $0.notes) } + [e.marker])
        guard let first = adjacent.first else { return .create(title: e.title, start: e.start, end: e.end, notes: notes) }
        return .extend(id: first.id, start: min(e.start, first.start), end: max(e.end, adjacent.map(\.end).max()!),
                       notes: notes, remove: adjacent.dropFirst().map(\.id))
    }

    /// Events Cubi wrote (they carry a marker line) with this title, touching [start, end] within
    /// the gap, earliest first.
    static func ours(_ title: String, in nearby: [Existing], start: Double, end: Double) -> [Existing] {
        nearby.filter { $0.title == title && !markers(in: $0.notes).isEmpty && $0.end >= start - gap && $0.start <= end + gap }
            .sorted { $0.start < $1.start }
    }

    public static func markers(in notes: String?) -> [String] {
        (notes ?? "").split(separator: "\n")
            .filter { $0.hasPrefix(markerLinePrefix) }
            .flatMap { $0.dropFirst(markerLinePrefix.count).split(separator: " ").map(String.init) }
    }

    /// What the events said apart from their marker lines (blank lines and all), then the new
    /// entry's notes unless already there: a note someone typed into the event survives an extension.
    public static func body(of events: [Existing], plus new: String?) -> String {
        var lines: [String] = []
        for text in events.map(\.notes) + [new] {
            // Each note minus its marker line and the blank lines around it; inside, a blank line
            // stays (a paragraph break someone typed), a line already present is not repeated.
            var block = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix(markerLinePrefix) }[...]
            while block.first?.isEmpty == true { block = block.dropFirst() }
            while block.last?.isEmpty == true { block = block.dropLast() }
            for line in block where line.isEmpty ? (lines.last.map { !$0.isEmpty } ?? false) : !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func notes(body: String?, markers: [String]) -> String {
        var seen: [String] = []
        for m in markers where !seen.contains(m) { seen.append(m) }
        let text = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line = markerLinePrefix + seen.joined(separator: " ")
        return text.isEmpty ? line : text + "\n\n" + line
    }
}
