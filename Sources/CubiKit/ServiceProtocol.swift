import Foundation

/// What a plugin's service and Cubi say to each other (experimental): one JSON object per line.
/// The service writes events on stdout; Cubi writes on its stdin, `hello` first. Nothing here
/// acts: the app decides what an event does. An event the manifest did not list in
/// `service.events`, or one that breaks a rule below, is a problem for the log and is dropped.
public enum ServiceProtocol {
    /// Sent in `hello`. A service that gets another number, or no `hello` in time, should exit
    /// without starting anything: then it only ever runs under a Cubi that speaks its protocol.
    public static let version = 1
    /// Bytes in one line, without its newline; a longer line is dropped whole.
    public static let lineLimit = 16_384
    /// Lines a second, and `log` events a minute, the app takes from one service; the rest are dropped.
    public static let linesPerSecond = 10
    public static let logsPerMinute = 20
    /// At most one `notice` per this long from one service, as long as one stays on the island: a
    /// service passing on other people's actions must not make a Mac chime at will. More are dropped.
    public static let noticeInterval: Duration = .seconds(5)
    public static let titleLimit = 40
    public static let bodyLimit = 120
    public static let logLimit = 200
    /// Sounds and overlay effects are Cubi's own; a service picks one by name.
    public static let sounds: Set<String> = ["knock", "zap", "thud"]
    public static let effects: Set<String> = ["knock", "zap", "shake"]
    public static let presentFailures: Set<String> = ["busy", "unavailable"]
    /// A `present`'s message, as LAN Nudge's own limit.
    public static let messageLimit = 60
    /// How long a `present` stays up: the service's `seconds`, kept within these; 2 when it says none.
    public static let presentSeconds: ClosedRange<Double> = 1...10
    public static let defaultPresentSeconds = 2.0

    public enum Emphasis: String, Sendable, CaseIterable { case normal, loud }

    /// A `present`: what to draw and for how long. `color` is an index into the island's robot
    /// palette (SessionPalette), never a colour of the service's choosing.
    public struct Present: Sendable, Equatable {
        public var id: Int
        public var effect: String
        public var from: String
        public var windowShaken: Bool
        public var message: String?
        public var seconds: Double
        public var emphasis: Emphasis
        public var color: Int?

        public init(id: Int, effect: String, from: String, windowShaken: Bool = false, message: String? = nil,
                    seconds: Double = ServiceProtocol.defaultPresentSeconds, emphasis: Emphasis = .normal, color: Int? = nil) {
            self.id = id
            self.effect = effect
            self.from = from
            self.windowShaken = windowShaken
            self.message = message
            self.seconds = seconds
            self.emphasis = emphasis
            self.color = color
        }
    }

    public enum Event: Sendable, Equatable {
        /// A few seconds on the island.
        case notice(title: String, body: String?, sound: String?)
        /// Draw the overlay and answer with `presented` (same id).
        case present(Present)
        /// Kept for the panel to read.
        case state(JSONValue)
        case log(String)
        /// The answer to a `call` (same id).
        case reply(id: Int, ok: Bool, out: JSONValue?)

        public var kind: ToolPlugin.ServiceEvent {
            switch self {
            case .notice: return .notice
            case .present: return .present
            case .state: return .state
            case .log: return .log
            case .reply: return .reply
            }
        }
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case tooLong(Int)
        case notJSON
        case unknownType(String)
        case notDeclared(String)
        case badField(String, String)

        public var errorDescription: String? {
            switch self {
            case .tooLong(let n): return "一行 \(n) bytes，超過 \(lineLimit)，整行丟掉"
            case .notJSON: return "不是 JSON 物件"
            case .unknownType(let t): return "不認得的 type「\(t)」"
            case .notDeclared(let t): return "\(t) 沒有列在 service.events"
            case .badField(let f, let why): return "\(f)：\(why)"
            }
        }
    }

    /// One stdout line (without its newline) as an event the manifest allows.
    public static func event(_ line: Data, allowed: Set<ToolPlugin.ServiceEvent>) -> Result<Event, Problem> {
        guard line.count <= lineLimit else { return .failure(.tooLong(line.count)) }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line), v.object != nil else { return .failure(.notJSON) }
        guard let type = v["type"]?.string else { return .failure(.badField("type", "要是字串")) }
        guard let kind = ToolPlugin.ServiceEvent(rawValue: type) else { return .failure(.unknownType(quoted(type))) }
        guard allowed.contains(kind) else { return .failure(.notDeclared(type)) }
        do {
            switch kind {
            case .notice:
                return .success(.notice(title: try text(v, "title", titleLimit), body: try optionalText(v, "body", bodyLimit),
                                        sound: try optionalName(v, "sound", in: sounds)))
            case .present:
                return .success(.present(Present(
                    id: try id(v), effect: try name(v, "effect", in: effects), from: try text(v, "from", titleLimit),
                    windowShaken: try flag(v, "windowShaken") ?? false, message: try optionalText(v, "message", messageLimit),
                    seconds: try seconds(v), emphasis: try optionalName(v, "emphasis", in: Set(Emphasis.allCases.map(\.rawValue))).flatMap(Emphasis.init) ?? .normal,
                    color: try paletteIndex(v))))
            case .state:
                guard let data = v["data"], data.object != nil else { throw Problem.badField("data", "要是物件") }
                return .success(.state(data))
            case .log:
                return .success(.log(try text(v, "text", logLimit)))
            case .reply:
                guard let ok = try flag(v, "ok") else { throw Problem.badField("ok", "要是 true 或 false") }
                return .success(.reply(id: try id(v), ok: ok, out: v["out"]))
            }
        } catch let p as Problem {
            return .failure(p)
        } catch {
            return .failure(.notJSON)
        }
    }

    // MARK: - What the island shows

    /// For a `notice`: its title, then whose it is (the plugin's name, which the service cannot
    /// choose). The island is where Cubi itself speaks. The body does not fit the wing and only goes
    /// to the log, for now.
    public static func noticeLines(title: String, plugin: String) -> [String] {
        [title, plugin]
    }

    // MARK: - From the panel

    /// How long a panel's `service.call` waits for the service's `reply`.
    public static let callTimeout: Duration = .seconds(10)

    /// A panel's `service.call`, from the bridge's `args`: the action, then optionally a JSON object
    /// of arguments. The action is named as a manifest command is.
    public static func panelCall(_ args: [String]) -> Result<(action: String, args: JSONValue?), Problem> {
        guard let action = args.first, ToolPlugin.isValidActionName(action) else {
            return .failure(.badField("action", "動作名稱只能有小寫英數與 . _ -、第一個字要是英數，1–64 字"))
        }
        guard args.count <= 2 else { return .failure(.badField("args", "最多兩個：動作與參數")) }
        guard args.count == 2 else { return .success((action, nil)) }
        guard args[1].utf8.count <= lineLimit,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(args[1].utf8)), value.object != nil else {
            return .failure(.badField("args", "參數要是 JSON 物件，最多 \(lineLimit) bytes"))
        }
        return .success((action, value))
    }

    // MARK: - Cubi to the service

    /// The first line Cubi writes.
    public static func hello() -> String { line(["type": .string("hello"), "protocol": .number(Double(version))]) }

    /// A panel's `service.call`, passed on.
    public static func call(id: Int, action: String, args: JSONValue?) -> String {
        var o: [String: JSONValue] = ["type": .string("call"), "id": .number(Double(id)), "action": .string(action)]
        o["args"] = args
        return line(o)
    }

    /// The answer to `present`: drawn, or why not (`presentFailures`).
    public static func presented(id: Int, failure: String?) -> String {
        var o: [String: JSONValue] = ["type": .string("presented"), "id": .number(Double(id)), "ok": .bool(failure == nil)]
        o["reason"] = failure.map(JSONValue.string)
        return line(o)
    }

    private static func line(_ o: [String: JSONValue]) -> String { PluginIO.encode(JSONValue.object(o)) + "\n" }

    // MARK: - Fields

    private static func text(_ v: JSONValue, _ field: String, _ limit: Int) throws -> String {
        guard let s = try optionalText(v, field, limit) else { throw Problem.badField(field, "必填") }
        return s
    }

    /// One line of plain text that shows something: none of `isForbidden`, not only blanks, at most
    /// `limit` characters and `limit` × 4 scalars (a character can carry any number of combining marks).
    private static func optionalText(_ v: JSONValue, _ field: String, _ limit: Int) throws -> String? {
        guard let raw = v[field] else { return nil }
        guard let s = raw.string, !s.isEmpty else { throw Problem.badField(field, "要是非空字串") }
        guard s.count <= limit else { throw Problem.badField(field, "最多 \(limit) 字") }
        guard s.unicodeScalars.count <= limit * 4 else { throw Problem.badField(field, "組合符號太多（最多 \(limit * 4) 個 Unicode 字元）") }
        guard !s.unicodeScalars.contains(where: isForbidden) else { throw Problem.badField(field, "不能有控制字元、換行或文字方向控制字元") }
        guard s.unicodeScalars.contains(where: { !isBlank($0) }) else { throw Problem.badField(field, "不能只有空白") }
        return s
    }

    /// C0 (a newline included), DEL, C1, the line and paragraph separators, and Unicode's
    /// Bidi_Control characters, which can show a name backwards. Other format characters stay: an
    /// emoji family is joined by U+200D.
    static func isForbidden(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0..<0x20, 0x7f, 0x80...0x9f, 0x2028, 0x2029: return true
        default: return u.properties.isBidiControl
        }
    }

    /// Shows nothing on its own: whitespace and Unicode's default-ignorable code points (zero-width
    /// characters, the soft hyphen, the Hangul fillers…).
    static func isBlank(_ u: Unicode.Scalar) -> Bool {
        u.properties.isWhitespace || u.properties.isDefaultIgnorableCodePoint
    }

    /// The service's own words, for a log line: at most `limit` scalars, the forbidden ones as `\u{…}`.
    public static func quoted(_ s: String, limit: Int = 40) -> String {
        s.unicodeScalars.prefix(limit).map { isForbidden($0) ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
    }

    private static func name(_ v: JSONValue, _ field: String, in names: Set<String>) throws -> String {
        guard let s = try optionalName(v, field, in: names) else { throw Problem.badField(field, "必填") }
        return s
    }

    private static func optionalName(_ v: JSONValue, _ field: String, in names: Set<String>) throws -> String? {
        guard let raw = v[field] else { return nil }
        guard let s = raw.string, names.contains(s) else { throw Problem.badField(field, "只能是 \(names.sorted().joined(separator: "、"))") }
        return s
    }

    private static func id(_ v: JSONValue) throws -> Int {
        guard let n = v["id"]?.double.flatMap(Int.init(exactly:)), n >= 0 else { throw Problem.badField("id", "要是 0 以上的整數") }
        return n
    }

    /// Any number, kept within `presentSeconds`; anything else refuses the line.
    private static func seconds(_ v: JSONValue) throws -> Double {
        guard let raw = v["seconds"] else { return defaultPresentSeconds }
        guard let n = raw.double else { throw Problem.badField("seconds", "要是數字") }
        return min(max(n, presentSeconds.lowerBound), presentSeconds.upperBound)
    }

    private static func paletteIndex(_ v: JSONValue) throws -> Int? {
        guard let raw = v["color"] else { return nil }
        guard let n = raw.double.flatMap(Int.init(exactly:)), SessionPalette.colors.indices.contains(n) else {
            throw Problem.badField("color", "要是 0–\(SessionPalette.colors.count - 1) 的整數（島上機器人調色盤的編號）")
        }
        return n
    }

    private static func flag(_ v: JSONValue, _ field: String) throws -> Bool? {
        guard let raw = v[field] else { return nil }
        guard let b = raw.bool else { throw Problem.badField(field, "要是 true 或 false") }
        return b
    }
}
