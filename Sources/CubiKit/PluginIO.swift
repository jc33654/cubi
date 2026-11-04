import Foundation

/// What the app feeds a tool plugin's hook commands on stdin, and what it accepts back on stdout.
/// Both directions are JSON; the structs here are the only shapes the app will ever emit or read.
public enum PluginIO {
    public static let stdoutLimit = 65_536
    public static let maxRows = 10
    public static let maxActions = 5
    public static let valueLimit = 200
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

        public init(id: String, name: String, cwd: String?, projectDirectory: String?, agent: String, segments: [Segment]) {
            self.id = id; self.name = name; self.cwd = cwd; self.projectDirectory = projectDirectory
            self.agent = agent; self.segments = segments
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
        }

        public struct Action: Sendable, Equatable {
            public var label: String
            /// A hook-shaped command of the same plugin.
            public var action: String
        }

        public var title: String?
        public var rows: [Row]
        public var actions: [Action]
        public var error: String?

        /// `tool` is needed to check that every action names one of its hook commands.
        public static func parse(_ stdout: String, tool: ToolPlugin) throws -> WidgetOutput {
            let v = try PluginIO.decode(stdout)
            var rows: [Row] = []
            for (i, r) in (v["rows"]?.array ?? []).prefix(maxRows).enumerated() {
                guard let row = Row(r) else { throw ParseError.badRow(i + 1) }
                rows.append(row)
            }
            var actions: [Action] = []
            for a in (v["actions"]?.array ?? []).prefix(maxActions) {
                guard let label = a["label"]?.string, let action = a["action"]?.string else { throw ParseError.badAction("缺 label 或 action") }
                guard tool.isHook(action) else { throw ParseError.badAction("「\(action)」不是這個插件的 hook 命令") }
                actions.append(Action(label: String(label.prefix(titleLimit)), action: action))
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

    /// stdout of `tick`.
    public struct TickOutput: Sendable, Equatable {
        public var calendar: [CalendarEntry]

        public static func parse(_ stdout: String, now: Double = Date().timeIntervalSince1970) throws -> TickOutput {
            let v = try PluginIO.decode(stdout)
            let list = v["calendar"]?.array ?? []
            guard list.count <= maxCalendarEntries else { throw ParseError.badCalendar(list.count, "一次最多 \(maxCalendarEntries) 筆") }
            return TickOutput(calendar: try list.enumerated().map { try CalendarEntry.validate($1, index: $0 + 1, now: now) })
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
    /// `[label, value]` or `{label, value, url?}`.
    init?(_ v: JSONValue) {
        if let pair = v.array, pair.count == 2, let l = pair[0].string, let r = pair[1].string {
            self.init(label: l, value: r, url: nil)
        } else if let l = v["label"]?.string, let r = v["value"]?.string {
            if let url = v["url"]?.string {
                guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { return nil }
            }
            self.init(label: l, value: r, url: v["url"]?.string)
        } else {
            return nil
        }
        label = String(label.prefix(PluginIO.titleLimit))
        value = String(value.prefix(PluginIO.valueLimit))
    }
}
