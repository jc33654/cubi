import Foundation

/// A tool plugin: an HTML panel plus a table of commands its JavaScript may run. Described by
/// `plugins/<id>/manifest.json` with `"kind": "tool"`. Nothing here runs anything: the app asks
/// `invocation(action:args:)` for an executable and arguments, checked against the declared
/// argument types, and runs that without a shell.
public struct ToolPlugin: Sendable, Equatable {
    public struct Panel: Sendable, Equatable {
        /// Absolute path of the HTML file, re-read every time the panel opens.
        public var file: String
        public var width: Double
        public var height: Double
        /// Name of the `window.webkit.messageHandlers.<bridge>` the page posts to.
        public var bridge: String
    }

    public enum ArgType: Sendable, Equatable {
        /// `[A-Za-z0-9._-]`, 1–64 characters: file and asset names, never a path.
        case name
        /// Printable text up to 512 characters, not starting with `-` (so it cannot become an option).
        case value
        /// Free text up to 256 KB; only ever delivered on stdin.
        case text
        case choice([String])
    }

    public struct Command: Sendable, Equatable {
        /// argv, resolved: an absolute executable, then arguments; `$1`…`$n` stand for the caller's
        /// arguments (`$plugin` and relative executables were resolved when the manifest was parsed).
        public var run: [String]
        public var args: [ArgType]
        /// 1-based index of the argument fed on stdin instead of argv.
        public var stdin: Int?
        /// Treat stdout as a path and reveal it in the Finder.
        public var reveal: Bool
    }

    public struct Invocation: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        public var stdin: String?
        public var reveal: Bool
        /// The plugin's own directory, the command's working directory.
        public var directory: String
    }

    /// `session.info`: the command that fills the plugin's section of a session's detail card.
    public struct SessionHook: Sendable, Equatable {
        public var info: String
        /// Seconds between refreshes while the session is selected.
        public var refresh: Int
    }

    /// `tick`: the command run every `every` seconds with all live sessions, whose output may
    /// ask the app for things only it can do (calendar events).
    public struct TickHook: Sendable, Equatable {
        public var action: String
        public var every: Int
    }

    public static let defaultBridge = "cubi"
    public static let textLimit = 262_144
    public static let minRefresh = 10
    public static let minTickInterval = 30
    /// Handled by the panel itself (native pickers, starting a Claude Code session); a manifest
    /// cannot take these names.
    public static let reservedActions: Set<String> = ["pick.file", "pick.dir", "session.new"]

    public var id: String
    public var displayName: String
    /// Where the manifest lives; `$plugin` in argv and relative executables resolve against it.
    public var directory: String
    public var panel: Panel
    public var commands: [String: Command]
    public var session: SessionHook?
    public var tick: TickHook?

    public enum LoadError: Error, Equatable, LocalizedError {
        case badID(String)
        case missingField(String)
        case badCommand(String, String)
        case badHook(String, String)

        public var errorDescription: String? {
            switch self {
            case .badID(let id): return "id「\(id)」不合法（小寫英數與 -，最多 24 字）"
            case .missingField(let f): return "缺少欄位 \(f)"
            case .badCommand(let action, let why): return "commands.\(action)：\(why)"
            case .badHook(let field, let why): return "\(field)：\(why)"
            }
        }
    }

    public enum InvokeError: Error, Equatable, LocalizedError {
        case unknownAction(String)
        case argumentCount(expected: Int, got: Int)
        case badArgument(index: Int, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unknownAction(let a): return "不允許的請求：\(a)"
            case .argumentCount(let e, let g): return "參數數量不符（要 \(e) 個，收到 \(g) 個）"
            case .badArgument(let i, let r): return "第 \(i) 個參數不合法：\(r)"
            }
        }
    }

    // MARK: - Loading

    public static func load(url: URL, home: String) throws -> ToolPlugin {
        let data = try Data(contentsOf: url)
        return try parse(try JSONDecoder().decode(JSONValue.self, from: data),
                         baseDirectory: url.deletingLastPathComponent().path, home: home)
    }

    public static func parse(_ m: JSONValue, baseDirectory: String, home: String) throws -> ToolPlugin {
        guard let id = m["id"]?.string else { throw LoadError.missingField("id") }
        guard AgentID.isValid(id) else { throw LoadError.badID(id) }
        guard let name = m["name"]?.string else { throw LoadError.missingField("name") }
        guard let file = m["panel"]?["file"]?.string else { throw LoadError.missingField("panel.file") }
        let panel = Panel(file: absolutePath(file, base: baseDirectory, home: home),
                          width: m["panel"]?["width"]?.double ?? 900,
                          height: m["panel"]?["height"]?.double ?? 640,
                          bridge: m["panel"]?["bridge"]?.string ?? defaultBridge)

        var commands: [String: Command] = [:]
        for (action, spec) in m["commands"]?.object ?? [:] {
            if reservedActions.contains(action) { throw LoadError.badCommand(action, "保留給面板內建的選擇器，不能自己定義") }
            guard let run = spec["run"]?.array?.compactMap(\.string), !run.isEmpty, !run[0].isEmpty else {
                throw LoadError.badCommand(action, "run 要是非空的字串陣列")
            }
            // The executable may be absolute, `~`, `$plugin/…`, or a path relative to the plugin
            // directory; a bare name is not looked up on PATH (no shell), so it is refused.
            guard run[0].contains("/") || run[0] == "~" else { throw LoadError.badCommand(action, "執行檔要是路徑（絕對、~ 或相對插件目錄，不能只寫名字）") }
            let executable = absolutePath(pluginPath(run[0], base: baseDirectory), base: baseDirectory, home: home)
            let argv = run.dropFirst().map { pluginPath($0, base: baseDirectory) }
            var args: [ArgType] = []
            for (i, a) in (spec["args"]?.array ?? []).enumerated() {
                switch a.string {
                case "name": args.append(.name)
                case "value": args.append(.value)
                case "text": args.append(.text)
                case nil:
                    guard let choices = a["enum"]?.array?.compactMap(\.string), !choices.isEmpty else {
                        throw LoadError.badCommand(action, "args[\(i)] 要是 name、value、text 或 {enum: […]}")
                    }
                    args.append(.choice(choices))
                case .some(let other):
                    throw LoadError.badCommand(action, "args[\(i)] 不認得的型別「\(other)」")
                }
            }
            if let raw = spec["stdin"], raw.double.flatMap(Int.init(exactly:)) == nil { throw LoadError.badCommand(action, "stdin 要是整數") }
            let stdin = spec["stdin"]?.double.flatMap(Int.init(exactly:))
            if let s = stdin, s < 1 || s > args.count { throw LoadError.badCommand(action, "stdin 要在 1…\(args.count)") }
            for (i, a) in args.enumerated() where a == .text && stdin != i + 1 {
                throw LoadError.badCommand(action, "args[\(i)] 是 text，只能經 stdin 傳")
            }
            for word in argv {
                if let n = placeholder(word) {
                    guard n >= 1, n <= args.count else { throw LoadError.badCommand(action, "\(word) 沒有對應的 args") }
                    if n == stdin { throw LoadError.badCommand(action, "\(word) 已經指定走 stdin") }
                }
            }
            commands[action] = Command(run: [executable] + argv, args: args, stdin: stdin,
                                       reveal: spec["reveal"]?.bool ?? false)
        }

        var session: SessionHook?
        if let s = m["session"] {
            guard let info = s["info"]?.string else { throw LoadError.missingField("session.info") }
            try checkHook("session.info", action: info, in: commands)
            session = SessionHook(info: info, refresh: try seconds(s["refresh"], field: "session.refresh", least: minRefresh))
        }
        var tick: TickHook?
        if let t = m["tick"] {
            guard let action = t["action"]?.string else { throw LoadError.missingField("tick.action") }
            try checkHook("tick.action", action: action, in: commands)
            tick = TickHook(action: action, every: try seconds(t["every"], field: "tick.every", least: minTickInterval))
        }
        return ToolPlugin(id: id, displayName: name, directory: baseDirectory, panel: panel, commands: commands,
                          session: session, tick: tick)
    }

    /// An interval in whole seconds, `least` or more; absent means 60. A huge or fractional number is
    /// an error, not a crash (`Int(Double)` traps on 1e300).
    static func seconds(_ v: JSONValue?, field: String, least: Int) throws -> Int {
        guard let v else { return 60 }
        guard let n = v.double.flatMap(Int.init(exactly:)) else { throw LoadError.badHook(field, "要是整數秒") }
        guard n >= least else { throw LoadError.badHook(field, "最少 \(least) 秒") }
        return n
    }

    /// A hook command takes exactly one `text` argument on stdin (the JSON the app feeds it) and
    /// answers on stdout, so it cannot also be a `reveal` command.
    static func checkHook(_ field: String, action: String, in commands: [String: Command]) throws {
        guard let c = commands[action] else { throw LoadError.badHook(field, "沒有這個命令「\(action)」") }
        guard c.args == [.text], c.stdin == 1 else { throw LoadError.badHook(field, "「\(action)」要宣告 args: [\"text\"], stdin: 1") }
        guard !c.reveal else { throw LoadError.badHook(field, "「\(action)」不能同時 reveal") }
    }

    public func isHook(_ action: String) -> Bool {
        (try? Self.checkHook("", action: action, in: commands)) != nil
    }

    // MARK: - Invoking

    public func invocation(action: String, args: [String]) throws -> Invocation {
        guard let command = commands[action] else { throw InvokeError.unknownAction(action) }
        guard args.count == command.args.count else {
            throw InvokeError.argumentCount(expected: command.args.count, got: args.count)
        }
        for (i, (value, type)) in zip(args, command.args).enumerated() {
            if let reason = Self.problem(with: value, as: type) { throw InvokeError.badArgument(index: i + 1, reason: reason) }
        }
        let arguments = command.run.dropFirst().map { word -> String in
            guard let n = Self.placeholder(word) else { return word }
            return args[n - 1]
        }
        return Invocation(executable: command.run[0], arguments: Array(arguments),
                          stdin: command.stdin.map { args[$0 - 1] }, reveal: command.reveal, directory: directory)
    }

    static func problem(with value: String, as type: ArgType) -> String? {
        switch type {
        case .name:
            guard !value.isEmpty, value.count <= 64 else { return "名稱要 1–64 字" }
            if value == "." || value == ".." { return "名稱不能是 . 或 .." }
            let ok = value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-") }
            return ok ? nil : "名稱只能有英數、.、_、-"
        case .value:
            guard !value.isEmpty, value.count <= 512 else { return "值要 1–512 字" }
            if value.hasPrefix("-") { return "值不能以 - 開頭" }
            let ok = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
            return ok ? nil : "值不能有控制字元"
        case .text:
            return value.utf8.count <= textLimit ? nil : "內容超過 \(textLimit / 1024) KB"
        case .choice(let choices):
            return choices.contains(value) ? nil : "要是 \(choices.joined(separator: "、")) 之一"
        }
    }

    /// `$3` → 3; anything else nil.
    static func placeholder(_ word: String) -> Int? {
        guard word.hasPrefix("$"), let n = Int(word.dropFirst()) else { return nil }
        return n
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    static func absolutePath(_ path: String, base: String, home: String) -> String {
        let expanded = expandTilde(path, home: home)
        return expanded.hasPrefix("/") ? expanded : base + "/" + expanded
    }

    /// `$plugin` or `$plugin/x` → the plugin directory; anything else unchanged.
    static func pluginPath(_ word: String, base: String) -> String {
        if word == "$plugin" { return base }
        if word.hasPrefix("$plugin/") { return base + word.dropFirst("$plugin".count) }
        return word
    }
}
