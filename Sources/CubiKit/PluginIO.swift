import Foundation

/// What the app feeds a tool plugin's hook commands on stdin, and what it accepts back on stdout.
/// Both directions are JSON; the structs here are the only shapes the app will ever emit or read.
public enum PluginIO {
    public static let stdoutLimit = 65_536
    public static let maxRows = 10
    public static let maxActions = 5
    public static let valueLimit = 200
    /// A line the user types for an action: printable, this long at most.
    public static let inputLimit = 512
    public static let titleLimit = 60
    public static let calendarTitleLimit = 120
    public static let maxCalendarEntries = 50
    /// One event may not span more than a day, nor start more than a year from now.
    public static let maxCalendarSpan: Double = 24 * 3600
    public static let maxCalendarDistance: Double = 366 * 24 * 3600

    /// One stretch of session activity; seconds since 1970. `open` is the stretch still running.
    public struct Segment: Sendable, Equatable, Codable {
        public var start: Double
        public var end: Double
        public var open: Bool

        public init(start: Double, end: Double, open: Bool) {
            self.start = start; self.end = end; self.open = open
        }
    }

    /// stdin of `session.info` and of every widget action.
    public struct SessionInput: Sendable, Equatable, Codable {
        public var id: String
        public var name: String
        public var cwd: String?
        public var projectDirectory: String?
        public var agent: String
        public var segments: [Segment]
        /// What the user typed for an action that asked for `input`; absent otherwise.
        public var input: String?

        public init(id: String, name: String, cwd: String?, projectDirectory: String?, agent: String, segments: [Segment], input: String? = nil) {
            self.id = id; self.name = name; self.cwd = cwd; self.projectDirectory = projectDirectory
            self.agent = agent; self.segments = segments; self.input = input
        }

        public func json() -> String { PluginIO.encode(self) }
    }

    /// stdin of `tick`.
    public struct TickInput: Sendable, Equatable, Codable {
        public var now: Double
        public var sessions: [SessionInput]

        public init(now: Double, sessions: [SessionInput]) { self.now = now; self.sessions = sessions }

        public func json() -> String { PluginIO.encode(self) }
    }

    /// stdout of `session.info`: the plugin's section of the detail card.
    public struct WidgetOutput: Sendable, Equatable {
        public struct Row: Sendable, Equatable {
            public var label: String
            public var value: String
            /// http(s) only; the label becomes a link that opens in the browser.
            public var url: String?
            /// Colours the value (and a dot before it).
            public var tone: Tone? = nil
            /// 0…1: a thin bar under the value.
            public var progress: Double? = nil
            /// A value the app keeps ticking every second.
            public var clock: Clock? = nil
        }

        public enum Tone: String, Sendable, Equatable { case good, warning, danger, info, neutral }

        /// Shown as `offset ± (now − since)` seconds, counting down when `down`; below zero the
        /// app writes it as overtime. Times are epoch seconds on this Mac's own clock.
        public struct Clock: Sendable, Equatable {
            public var since: Double
            public var offset: Double
            public var down: Bool

            public func seconds(at now: Double) -> Double {
                let elapsed = max(0, now - since)
                return down ? offset - elapsed : offset + elapsed
            }

            /// nil unless every number is usable: `since` finite and within a year of now, `offset` finite.
            static func parse(_ v: JSONValue?, now: Double) -> Clock? {
                guard let v, let since = v["since"]?.double else { return nil }
                let offset = v["offset"]?.double ?? 0
                guard since.isFinite, offset.isFinite, abs(offset) <= maxCalendarDistance,
                      abs(since - now) <= maxCalendarDistance else { return nil }
                // A `since` still in the future is kept as is: `seconds` holds at `offset` until it arrives.
                return Clock(since: since, offset: offset, down: v["down"]?.bool ?? false)
            }
        }

        public struct Action: Sendable, Equatable {
            public var label: String
            /// A hook-shaped command of the same plugin.
            public var action: String
            /// When set, the app asks the user for a line of text (this is the prompt) and passes
            /// it as `input`; the action is not run when the user cancels.
            public var input: String?
            /// A value the plugin chose for this button (say, the ticket a 解除 button is for),
            /// passed as `input` without asking anyone. Ignored when `input` is set.
            public var arg: String?
            /// An SF Symbol name: the button shows the icon, the label becomes its tooltip.
            public var icon: String? = nil
        }

        public var title: String?
        public var rows: [Row]
        public var actions: [Action]
        public var error: String?

        /// `tool` is needed to check that every action names one of its hook commands.
        public static func parse(_ stdout: String, tool: ToolPlugin, now: Double = Date().timeIntervalSince1970) throws -> WidgetOutput {
            let v = try PluginIO.decode(stdout)
            var rows: [Row] = []
            for (i, r) in (v["rows"]?.array ?? []).prefix(maxRows).enumerated() {
                guard let row = Row(r, now: now) else { throw ParseError.badRow(i + 1) }
                rows.append(row)
            }
            var actions: [Action] = []
            for a in (v["actions"]?.array ?? []).prefix(maxActions) {
                guard let label = a["label"]?.string, let action = a["action"]?.string else { throw ParseError.badAction("缺 label 或 action") }
                guard tool.isHook(action) else { throw ParseError.badAction("「\(action)」不是這個插件的 hook 命令") }
                let prompt = a["input"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(titleLimit)) }
                actions.append(Action(label: String(label.prefix(titleLimit)), action: action, input: prompt,
                                      arg: prompt == nil ? a["arg"]?.string.flatMap(cleanInput) : nil,
                                      icon: a["icon"]?.string.flatMap { isValidSymbol($0) ? $0 : nil }))
            }
            return WidgetOutput(title: v["title"]?.string.map { String($0.prefix(titleLimit)) }, rows: rows, actions: actions,
                                error: v["error"]?.string)
        }
    }

    /// One event the app writes to the calendar on a plugin's behalf.
    public struct CalendarEntry: Sendable, Equatable {
        public var title: String
        public var start: Double
        public var end: Double
        public var notes: String?
        /// Stable id the app embeds in the event so a resend does not create a second event.
        public var marker: String

        public init(title: String, start: Double, end: Double, notes: String?, marker: String) {
            self.title = title; self.start = start; self.end = end; self.notes = notes; self.marker = marker
        }

        static func validate(_ v: JSONValue, index: Int, now: Double) throws -> CalendarEntry {
            guard let title = v["title"]?.string, !title.isEmpty else { throw ParseError.badCalendar(index, "缺 title") }
            guard let start = v["start"]?.double, let end = v["end"]?.double, end > start, end - start <= maxCalendarSpan else {
                throw ParseError.badCalendar(index, "start/end 不合法（要 start < end，且不超過 24 小時）")
            }
            // Milliseconds passed as seconds would land in the year 57000 and never be found again.
            guard abs(start - now) <= maxCalendarDistance else { throw ParseError.badCalendar(index, "start 要在現在前後一年內（秒，不是毫秒）") }
            guard let marker = v["marker"]?.string, isValidMarker(marker) else { throw ParseError.badCalendar(index, "marker 只能有英數、:._-，1–80 字") }
            return CalendarEntry(title: String(title.prefix(calendarTitleLimit)), start: start, end: end,
                                 notes: v["notes"]?.string, marker: marker)
        }
    }

    /// stdout of `tick`. A bad entry is dropped with a note in `problems`; the rest still count,
    /// since a plugin resends everything each tick and one bad line must not hold up the others.
    public struct TickOutput: Sendable, Equatable {
        public var calendar: [CalendarEntry]
        public var problems: [String]

        public static func parse(_ stdout: String, now: Double = Date().timeIntervalSince1970) throws -> TickOutput {
            let v = try PluginIO.decode(stdout)
            let list = v["calendar"]?.array ?? []
            var out = TickOutput(calendar: [], problems: [])
            if list.count > maxCalendarEntries { out.problems.append("calendar 有 \(list.count) 筆，只收前 \(maxCalendarEntries) 筆") }
            for (i, item) in list.prefix(maxCalendarEntries).enumerated() {
                do { out.calendar.append(try CalendarEntry.validate(item, index: i + 1, now: now)) }
                catch { out.problems.append(error.localizedDescription) }
            }
            return out
        }
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case tooLarge
        case notJSON(String)
        case badRow(Int)
        case badAction(String)
        case badCalendar(Int, String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "輸出超過 \(stdoutLimit / 1024) KB"
            case .notJSON(let head): return "輸出不是 JSON 物件：\(head)"
            case .badRow(let i): return "rows[\(i)] 要是 [label, value] 或 {label, value, url}"
            case .badAction(let why): return "actions：\(why)"
            case .badCalendar(let i, let why): return "calendar[\(i)]：\(why)"
            }
        }
    }

    /// What the user typed: tabs and line breaks become spaces (two keys pasted on two lines stay
    /// two keys), other control characters go, trimmed, cut to `inputLimit`; nil when nothing is left.
    public static func cleanInput(_ s: String) -> String? {
        let kept = String(String.UnicodeScalarView(s.unicodeScalars.compactMap { c in
            if c == "\t" || c == "\n" || c == "\r" { return " " }
            return c.value >= 0x20 && c.value != 0x7f ? c : nil
        })).trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : String(kept.prefix(inputLimit))
    }

    /// SF Symbol names: dot-separated words of lower-case letters and digits, 1–40 characters.
    public static func isValidSymbol(_ s: String) -> Bool {
        (1...40).contains(s.count)
            && s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            }
    }

    public static func isValidMarker(_ s: String) -> Bool {
        (1...80).contains(s.count) && s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ":._-".unicodeScalars.contains($0))
        }
    }

    static func decode(_ stdout: String) throws -> JSONValue {
        guard stdout.utf8.count <= stdoutLimit else { throw ParseError.tooLarge }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8)), v.object != nil else {
            throw ParseError.notJSON(String(stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))
        }
        return v
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

extension PluginIO.WidgetOutput.Row {
    /// `[label, value]` or `{label, value, url?, tone?, progress?, clock?}`. An unknown tone, a
    /// progress outside 0…1 or an unusable clock is left out, not an error.
    init?(_ v: JSONValue, now: Double) {
        if let pair = v.array, pair.count == 2, let l = pair[0].string, let r = pair[1].string {
            self.init(label: l, value: r, url: nil)
        } else if let l = v["label"]?.string, let r = v["value"]?.string {
            if let url = v["url"]?.string {
                guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { return nil }
            }
            self.init(label: l, value: r, url: v["url"]?.string)
            tone = v["tone"]?.string.flatMap(PluginIO.WidgetOutput.Tone.init(rawValue:))
            progress = v["progress"]?.double.flatMap { (0...1).contains($0) ? $0 : nil }
            clock = PluginIO.WidgetOutput.Clock.parse(v["clock"], now: now)
        } else {
            return nil
        }
        label = String(label.prefix(PluginIO.titleLimit))
        value = String(value.prefix(PluginIO.valueLimit))
    }
}
