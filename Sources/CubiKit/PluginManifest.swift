import Foundation

/// What every `plugins/<id>/manifest.json` goes through before its own parser (tool or agent)
/// sees it: the schema version, the kind, the folder name, and keys no parser reads (warned
/// about, so a typo shows; `x-` keys are the author's own). The registry, `--validate-plugin` and
/// `--tool-run` all load through here.
public enum PluginManifest {
    /// The newest manifest schema this Cubi reads; a manifest without `schema` is 1.
    public static let supportedSchema = 1

    public enum Plugin: Sendable {
        case tool(ToolPlugin)
        case agent(ManifestPlugin)

        public var id: String {
            switch self {
            case .tool(let t): return t.id
            case .agent(let a): return a.id
            }
        }
    }

    public struct Loaded: Sendable {
        public var plugin: Plugin
        /// Keys no parser reads, as `panel.wdith`; the plugin still loads.
        public var warnings: [String]
    }

    public enum LoadError: Error, Equatable, LocalizedError {
        case unreadable(String)
        case notJSON(String)
        case badSchema
        case newerSchema(Int)
        case badKind(String)
        case folderMismatch(folder: String, id: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "讀不到 manifest.json：\(why)"
            case .notJSON(let why): return "manifest.json 不是 JSON 物件：\(why)"
            case .badSchema: return "schema：要是 1 以上的整數"
            case .newerSchema(let n): return "schema：這份 manifest 是第 \(n) 版，這個 Cubi 只認得到第 \(supportedSchema) 版，請更新 Cubi"
            case .badKind(let k): return "kind：只能是 tool 或 agent（或不寫，等於 agent），不是 \(k)"
            case .folderMismatch(let folder, let id): return "資料夾名「\(folder)」要跟 id「\(id)」一樣"
            }
        }
    }

    public static func load(directory: URL, home: String) throws -> Loaded {
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent("manifest.json")) }
        catch { throw LoadError.unreadable(error.localizedDescription) }
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw LoadError.notJSON(String(describing: error).prefix(160).description) }
        return try check(value, folder: directory.lastPathComponent, baseDirectory: directory.path, home: home)
    }

    public static func check(_ m: JSONValue, folder: String, baseDirectory: String, home: String) throws -> Loaded {
        guard m.object != nil else { throw LoadError.notJSON("最外層要是 { … }") }
        if let raw = m["schema"] {
            guard let n = raw.double.flatMap(Int.init(exactly:)), n >= 1 else { throw LoadError.badSchema }
            guard n <= supportedSchema else { throw LoadError.newerSchema(n) }
        }
        let isTool: Bool
        switch m["kind"] {
        case nil, .string("agent"): isTool = false
        case .string("tool"): isTool = true
        case .some(let other): throw LoadError.badKind(describe(other))
        }
        if let id = m["id"]?.string, id != folder { throw LoadError.folderMismatch(folder: folder, id: id) }
        if isTool {
            return Loaded(plugin: .tool(try ToolPlugin.parse(m, baseDirectory: baseDirectory, home: home)), warnings: unknownKeys(m, Self.toolKeys))
        }
        return Loaded(plugin: .agent(try ManifestPlugin.parse(m)), warnings: unknownKeys(m, Self.agentKeys))
    }

    /// The keys each parser reads, nested. `each` stands for every member of an object
    /// (`commands.<action>`) or an array (`secrets[]`).
    indirect enum Keys: Sendable {
        case leaf
        case fields([String: Keys])
        case each(Keys)
    }

    static let toolKeys: Keys = .fields([
        "schema": .leaf, "kind": .leaf, "id": .leaf, "name": .leaf, "builtins": .leaf,
        "panel": .fields(["file": .leaf, "width": .leaf, "height": .leaf, "bridge": .leaf, "style": .leaf]),
        "commands": .each(.fields(["run": .leaf, "args": .leaf, "stdin": .leaf, "reveal": .leaf, "sessionAllowed": .leaf])),
        "session": .fields(["info": .leaf, "refresh": .leaf]),
        "tick": .fields(["action": .leaf, "every": .leaf]),
        "service": .fields(["run": .leaf, "restart": .leaf, "events": .leaf]),
    ])

    static let agentKeys: Keys = .fields([
        "schema": .leaf, "kind": .leaf, "id": .leaf, "name": .leaf, "color": .leaf, "capabilities": .leaf,
        "secrets": .each(.fields(["key": .leaf, "label": .leaf, "required": .leaf])),
        "install": .fields(["mode": .leaf, "file": .leaf, "instructions": .leaf,
                            "entries": .each(.fields(["event": .leaf, "command": .leaf, "timeout": .leaf]))]),
        "events": .each(.fields(["canonical": .leaf, "map": .fields(Dictionary(uniqueKeysWithValues: ManifestPlugin.mapFields.map { ($0, Keys.leaf) }))])),
    ])

    /// `panel.wdith`-style paths of keys `known` does not list; `x-` keys are skipped.
    static func unknownKeys(_ v: JSONValue, _ known: Keys, at path: String = "") -> [String] {
        switch known {
        case .leaf:
            return []
        case .fields(let fields):
            guard let object = v.object else { return [] }
            return object.keys.sorted().flatMap { key -> [String] in
                let here = path.isEmpty ? key : path + "." + key
                if key.hasPrefix("x-") { return [] }
                guard let sub = fields[key] else { return ["不認得的欄位 \(here)（拼錯了嗎？自己用的欄位請以 x- 開頭）"] }
                return unknownKeys(object[key]!, sub, at: here)
            }
        case .each(let sub):
            if let object = v.object { return object.keys.sorted().flatMap { unknownKeys(object[$0]!, sub, at: path + "." + $0) } }
            if let array = v.array { return array.indices.flatMap { unknownKeys(array[$0], sub, at: path + "[\($0)]") } }
            return []
        }
    }

    private static func describe(_ v: JSONValue) -> String {
        if let s = v.string { return "「\(s)」" }
        return PluginIO.encode(v)
    }

    // MARK: - What only the disk can tell (`--validate-plugin`)

    /// The panel file is there, and every command's executable exists and may be run. Commands
    /// sharing one executable are named together.
    public static func fileProblems(_ tool: ToolPlugin, fileManager fm: FileManager = .default) -> [String] {
        var problems: [String] = []
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: tool.panel.file, isDirectory: &isDir) || isDir.boolValue {
            problems.append("panel.file：找不到 \(tool.panel.file)")
        }
        let byExecutable = Dictionary(grouping: tool.commands.keys.sorted()) { tool.commands[$0]!.run[0] }
        for (path, actions) in byExecutable.sorted(by: { $0.key < $1.key }) {
            let who = "commands." + actions.joined(separator: "、")
            if !fm.fileExists(atPath: path, isDirectory: &isDir) {
                problems.append("\(who)：找不到執行檔 \(path)")
            } else if isDir.boolValue || !fm.isExecutableFile(atPath: path) {
                problems.append("\(who)：\(path) 不能執行（chmod +x，或第一格寫 /usr/bin/python3、腳本放第二格）")
            }
        }
        return problems
    }

    public struct Report: Sendable, Equatable {
        public var errors: [String]
        public var warnings: [String]
        /// One line saying what loaded, when it did.
        public var summary: String?
    }

    /// Everything `--validate-plugin` prints: what loading says, then the disk checks.
    public static func validate(directory: URL, home: String, fileManager fm: FileManager = .default) -> Report {
        let loaded: Loaded
        do { loaded = try load(directory: directory, home: home) }
        catch { return Report(errors: [(error as? LocalizedError)?.errorDescription ?? "\(error)"], warnings: [], summary: nil) }
        switch loaded.plugin {
        case .tool(let t):
            let hooks = [t.session.map { _ in "session hook" }, t.tick.map { _ in "tick" }, t.service.map { _ in "service" }].compactMap { $0 }
            return Report(errors: fileProblems(t, fileManager: fm), warnings: loaded.warnings,
                          summary: "工具套件 \(t.id)：\(t.commands.count) 個指令" + hooks.map { "、" + $0 }.joined())
        case .agent(let a):
            return Report(errors: [], warnings: loaded.warnings, summary: "agent 套件 \(a.id)：\(a.events.count) 個事件（實驗中）")
        }
    }
}

public extension ToolPlugin {
    /// Lower-case letters, digits and `._-`, 1–64 characters, starting with a letter or digit (so it
    /// never reads as a flag): the same string must work as a key in the JS bridge, an argument to
    /// `cubi --tool-run`, and a word in a restricted session's allow rule.
    static func isValidActionName(_ s: String) -> Bool {
        let alnum = { (c: Unicode.Scalar) in ("a"..."z").contains(c) || ("0"..."9").contains(c) }
        guard (1...64).contains(s.count), let first = s.unicodeScalars.first, alnum(first) else { return false }
        return s.unicodeScalars.allSatisfy { alnum($0) || "._-".unicodeScalars.contains($0) }
    }
}
