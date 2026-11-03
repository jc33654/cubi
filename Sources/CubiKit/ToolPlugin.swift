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
        /// argv: an absolute executable, then arguments; `$1`…`$n` stand for the caller's arguments.
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
    }

    public static let defaultBridge = "cubi"
    public static let textLimit = 262_144
    /// Handled by the panel itself (native pickers); a manifest cannot take these names.
    public static let reservedActions: Set<String> = ["pick.file", "pick.dir"]

    public var id: String
    public var displayName: String
    public var panel: Panel
    public var commands: [String: Command]

    public enum LoadError: Error, Equatable, LocalizedError {
        case badID(String)
        case missingField(String)
        case badCommand(String, String)

        public var errorDescription: String? {
            switch self {
            case .badID(let id): return "id「\(id)」不合法（小寫英數與 -，最多 24 字）"
            case .missingField(let f): return "缺少欄位 \(f)"
            case .badCommand(let action, let why): return "commands.\(action)：\(why)"
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
            guard let run = spec["run"]?.array?.compactMap(\.string), !run.isEmpty else {
                throw LoadError.badCommand(action, "run 要是非空的字串陣列")
            }
            let executable = expandTilde(run[0], home: home)
            guard executable.hasPrefix("/") else { throw LoadError.badCommand(action, "執行檔要是絕對路徑（可用 ~）") }
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
            let stdin = spec["stdin"]?.double.map { Int($0) }
            if let s = stdin, s < 1 || s > args.count { throw LoadError.badCommand(action, "stdin 要在 1…\(args.count)") }
            for (i, a) in args.enumerated() where a == .text && stdin != i + 1 {
                throw LoadError.badCommand(action, "args[\(i)] 是 text，只能經 stdin 傳")
            }
            for word in run.dropFirst() {
                if let n = placeholder(word) {
                    guard n >= 1, n <= args.count else { throw LoadError.badCommand(action, "\(word) 沒有對應的 args") }
                    if n == stdin { throw LoadError.badCommand(action, "\(word) 已經指定走 stdin") }
                }
            }
            commands[action] = Command(run: [executable] + run.dropFirst(), args: args, stdin: stdin,
                                       reveal: spec["reveal"]?.bool ?? false)
        }
        return ToolPlugin(id: id, displayName: name, panel: panel, commands: commands)
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
                          stdin: command.stdin.map { args[$0 - 1] }, reveal: command.reveal)
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
}
