import Foundation

// Reading a manifest into a ToolPlugin: every rule a manifest must meet is checked here.
extension ToolPlugin {
    public enum LoadError: Error, Equatable, LocalizedError {
        case badID(String)
        case missingField(String)
        case badCommand(String, String)
        case badHook(String, String)
        case badField(String, String)

        public var errorDescription: String? {
            switch self {
            case .badID(let id): return "id「\(id)」不合法（小寫英數與 -，最多 24 字）"
            case .missingField(let f): return "缺少欄位 \(f)"
            case .badCommand(let action, let why): return "commands.\(action)：\(why)"
            case .badHook(let field, let why), .badField(let field, let why): return "\(field)：\(why)"
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
        var style: PanelStyle?
        if let raw = m["panel"]?["style"], !raw.isNull {
            guard let s = raw.string.flatMap(PanelStyle.init(rawValue:)) else {
                throw LoadError.badField("panel.style", "只能是 \(PanelStyle.allCases.map(\.rawValue).joined(separator: "、"))")
            }
            style = s
        }
        let panel = Panel(file: absolutePath(file, base: baseDirectory, home: home),
                          width: m["panel"]?["width"]?.double ?? 900,
                          height: m["panel"]?["height"]?.double ?? 640,
                          bridge: m["panel"]?["bridge"]?.string ?? defaultBridge,
                          style: style)

        var commands: [String: Command] = [:]
        var builtins: Set<String> = []
        for b in m["builtins"]?.array ?? [] {
            guard let name = b.string, optionalBuiltins.contains(name) else {
                throw LoadError.badField("builtins", "只能是 \(optionalBuiltins.sorted().joined(separator: "、"))")
            }
            builtins.insert(name)
        }
        for (action, spec) in m["commands"]?.object ?? [:] {
            if reservedActions.contains(action) { throw LoadError.badCommand(action, "是面板內建的動作名稱，不能自己定義") }
            guard isValidActionName(action) else { throw LoadError.badCommand(action, "動作名稱只能有小寫英數與 . _ -、第一個字要是英數，1–64 字") }
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
                                       reveal: spec["reveal"]?.bool ?? false, sessionAllowed: spec["sessionAllowed"]?.bool ?? false)
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
        let service = try m["service"].map { try parseService($0, commands: commands) }
        return ToolPlugin(id: id, displayName: name, directory: baseDirectory, panel: panel, commands: commands,
                          session: session, tick: tick, builtins: builtins, service: service)
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
