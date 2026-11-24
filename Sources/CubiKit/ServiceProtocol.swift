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
    public static let titleLimit = 40
    public static let bodyLimit = 120
    public static let logLimit = 200
    /// Sounds and overlay effects are Cubi's own; a service picks one by name.
    public static let sounds: Set<String> = ["knock", "zap", "thud"]
    public static let effects: Set<String> = ["knock", "zap", "shake"]
    public static let presentFailures: Set<String> = ["busy", "unavailable"]

    public enum Event: Sendable, Equatable {
        /// A few seconds on the island.
        case notice(title: String, body: String?, sound: String?)
        /// Draw the overlay and answer with `presented` (same id).
        case present(id: Int, effect: String, from: String, windowShaken: Bool)
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
                return .success(.present(id: try id(v), effect: try name(v, "effect", in: effects), from: try text(v, "from", titleLimit),
                                         windowShaken: try flag(v, "windowShaken") ?? false))
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
    static func quoted(_ s: String, limit: Int = 40) -> String {
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

    private static func flag(_ v: JSONValue, _ field: String) throws -> Bool? {
        guard let raw = v[field] else { return nil }
        guard let b = raw.bool else { throw Problem.badField(field, "要是 true 或 false") }
        return b
    }
}

/// Splits a stream into lines. A line longer than the limit is dropped whole, its size reported
/// once it ends, and memory stays bounded while it goes on.
public struct ServiceLineReader: Sendable {
    public enum Item: Sendable, Equatable {
        case line(Data)
        case dropped(Int)
    }

    private var buffer = Data()
    private var overflow: Int?
    private let limit: Int

    public init(limit: Int = ServiceProtocol.lineLimit) { self.limit = limit }

    public mutating func push(_ bytes: Data) -> [Item] {
        var out: [Item] = []
        var rest = bytes[...]
        while let nl = rest.firstIndex(of: 0x0a) {
            let piece = rest[rest.startIndex..<nl]
            rest = rest[rest.index(after: nl)...]
            if let skipped = overflow {
                out.append(.dropped(skipped + piece.count))
                overflow = nil
            } else if buffer.count + piece.count > limit {
                out.append(.dropped(buffer.count + piece.count))
            } else {
                out.append(.line(buffer + piece))
            }
            buffer = Data()
        }
        if let skipped = overflow {
            overflow = skipped + rest.count
        } else if buffer.count + rest.count > limit {
            overflow = buffer.count + rest.count
            buffer = Data()
        } else {
            buffer.append(contentsOf: rest)
        }
        return out
    }

    /// At the end of the stream: what is left without a newline is the last line (dropped if it
    /// was too long), so a service that prints and exits does not lose it.
    public mutating func finish() -> [Item] {
        defer { buffer = Data(); overflow = nil }
        if let skipped = overflow { return [.dropped(skipped)] }
        return buffer.isEmpty ? [] : [.line(buffer)]
    }
}

/// At most `count` per `window`, the window sliding. Monotonic time, so setting the clock back
/// (by hand or NTP) does not hold a service's output up.
public struct ServiceRateLimit: Sendable {
    private let count: Int
    private let window: Duration
    private var times: [ContinuousClock.Instant] = []

    public init(count: Int, per window: Duration) {
        self.count = count
        self.window = window
    }

    public mutating func allow(at now: ContinuousClock.Instant) -> Bool {
        times.removeAll { $0.duration(to: now) >= window }
        guard times.count < count else { return false }
        times.append(now)
        return true
    }
}
