import Foundation

/// What a tool plugin's panel asks for with the built-in `session.new`: read from the JSON it
/// sends, checked, and worded for the question the user answers before anything opens.
public struct SessionNewSpec: Equatable, Sendable {
    public var directory: String
    public var prompt: String?
    public var restricted: Bool
    public var readDirs: [String]
    /// Actions of the asking plugin the session may run (through `cubi --tool-run`) without being
    /// asked. Everything else it tries to run is refused: a restricted session asks nothing.
    public var allowActions: [String] = []

    public static let fields: Set<String> = ["directory", "prompt", "restricted", "readDirs", "allowActions"]
    public static let maxReadDirs = 8
    public static let maxAllowActions = 4
    /// How much of the prompt the question shows in full.
    public static let shownPrompt = 400

    public enum ParseError: Error, Equatable {
        case shape
        case unknownField(String)
        case noDirectory(String)
        case restrictedNotBool
        case readDirsShape
        case readDirsWithoutRestricted
        case tooManyReadDirs
        case noReadDir(String)
        case privateReadDir(String)
        case guardedDirectory(String)
        case allowActionsShape
        case allowActionsWithoutRestricted
        case tooManyAllowActions
        case unknownAction(String)

        public var message: String {
            switch self {
            case .shape: return "session.new 要 args[0] 是 {\"directory\", \"prompt\"} 的 JSON"
            case .unknownField(let name): return "session.new 不認得欄位「\(name)」（只收 directory、prompt、restricted、readDirs、allowActions）"
            case .noDirectory(let path): return "找不到目錄 \(path)"
            case .restrictedNotBool: return "session.new 的 restricted 要是 true 或 false"
            case .readDirsShape: return "session.new 的 readDirs 要是目錄路徑的陣列"
            case .readDirsWithoutRestricted: return "session.new 的 readDirs 只能跟 restricted: true 一起用"
            case .tooManyReadDirs: return "session.new 的 readDirs 最多 \(maxReadDirs) 個"
            case .noReadDir(let path): return "找不到 readDirs 的目錄 \(path)"
            case .privateReadDir(let path): return "readDirs 不能是 \(path)（家目錄本身、根目錄，或放金鑰與憑證的目錄）"
            case .guardedDirectory(let path): return DirectoryGuard.Refusal.guarded(path).message
            case .allowActionsShape: return "session.new 的 allowActions 要是動作名稱的陣列"
            case .allowActionsWithoutRestricted: return "session.new 的 allowActions 只能跟 restricted: true 一起用"
            case .tooManyAllowActions: return "session.new 的 allowActions 最多 \(maxAllowActions) 個"
            case .unknownAction(let name): return "session.new 的 allowActions 只能填這個插件在 manifest 標了 \"sessionAllowed\": true 的動作，「\(name)」不是"
            }
        }
    }

    /// `isDirectory` answers for an absolute, standardized path. A field the spec does not know
    /// is refused: a plugin can ask for the restricted mode, never pass flags of its own.
    /// `home` is the user's home directory: it, the root, and the places keys and credentials
    /// live under it are never handed to a session as extra reading, whatever the question shows.
    ///
    /// `actions` are the commands the asking plugin's manifest marks `"sessionAllowed": true`:
    /// only those may be named in `allowActions` — a name, never a command line or a rule.
    ///
    /// `refuses` says whether a folder may not be used (the directory and every readDir): by
    /// default DirectoryGuard, which looks at the folders themselves on disk.
    public static func parse(_ raw: String?, promptLimit: Int, home: String = NSHomeDirectory(), actions: Set<String> = [],
                             refuses: (String) -> Bool = { DirectoryGuard.refusal($0) != nil },
                             isDirectory: (String) -> Bool) throws -> SessionNewSpec {
        guard let raw, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)), let object = value.object,
              let dir = object["directory"]?.string, !dir.isEmpty else { throw ParseError.shape }
        if let extra = object.keys.filter({ !fields.contains($0) }).sorted().first { throw ParseError.unknownField(extra) }
        let home = absolute(home, home: home)
        let directory = absolute(dir, home: home)
        guard directory.hasPrefix("/"), isDirectory(directory) else { throw ParseError.noDirectory(directory) }
        guard !isPrivate(directory, home: home), !refuses(directory) else { throw ParseError.guardedDirectory(directory) }
        let prompt = object["prompt"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(promptLimit)) }

        var restricted = false
        switch object["restricted"] {
        case nil, .some(.null): break
        case .some(.bool(let on)): restricted = on
        default: throw ParseError.restrictedNotBool   // 1, "true", a flag string: none of them turn it on
        }

        var readDirs: [String] = []
        switch object["readDirs"] {
        case nil, .some(.null): break
        case .some(.array(let items)):
            guard !items.isEmpty else { break }
            guard restricted else { throw ParseError.readDirsWithoutRestricted }
            guard items.count <= maxReadDirs else { throw ParseError.tooManyReadDirs }
            for item in items {
                guard let text = item.string, !text.isEmpty else { throw ParseError.readDirsShape }
                let path = absolute(text, home: home)
                guard path.hasPrefix("/"), isDirectory(path) else { throw ParseError.noReadDir(path) }
                guard !isPrivate(path, home: home), !refuses(path) else { throw ParseError.privateReadDir(path) }
                if !readDirs.contains(path) { readDirs.append(path) }
            }
        default: throw ParseError.readDirsShape
        }
        var allowActions: [String] = []
        switch object["allowActions"] {
        case nil, .some(.null): break
        case .some(.array(let items)):
            guard !items.isEmpty else { break }
            guard restricted else { throw ParseError.allowActionsWithoutRestricted }
            guard items.count <= maxAllowActions else { throw ParseError.tooManyAllowActions }
            for item in items {
                guard let name = item.string, !name.isEmpty else { throw ParseError.allowActionsShape }
                guard actions.contains(name) else { throw ParseError.unknownAction(name) }
                if !allowActions.contains(name) { allowActions.append(name) }
            }
        default: throw ParseError.allowActionsShape
        }
        return SessionNewSpec(directory: directory, prompt: prompt, restricted: restricted, readDirs: readDirs, allowActions: allowActions)
    }

    static let privateFolders = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config/gcloud", ".config/atlassian", "Library/Keychains"]

    /// The root, the home directory itself (everything hangs off them), or a folder of keys and
    /// credentials under home, or anything inside one.
    static func isPrivate(_ path: String, home: String) -> Bool {
        if path == "/" || path == home { return true }
        return privateFolders.contains { path == home + "/" + $0 || path.hasPrefix(home + "/" + $0 + "/") }
    }

    /// `~` is the given home (the same one the private folders are looked for under).
    static func absolute(_ path: String, home: String) -> String {
        let fromHome = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return ((fromHome as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// The body of the question: what the user agrees to by opening the session.
    public func confirmation() -> String {
        let shown = prompt.map { $0.count > Self.shownPrompt ? $0.prefix(Self.shownPrompt) + "…（共 \($0.count) 字）" : $0 } ?? "（沒有）"
        var lines = ["目錄：\(directory)", "要交給 Claude 的話：\(shown)"]
        guard restricted else { return lines.joined(separator: "\n") }
        lines.append(allowActions.isEmpty
            ? "受限模式：不套用你的允許規則，也不會問你。它只能讀檔，會改動東西的指令一律拒絕。"
            : "受限模式：不套用你的允許規則，也不會問你。只能執行這些動作：\(allowActions.joined(separator: "、"))；其他指令一律拒絕。")
        if !readDirs.isEmpty { lines.append("另外可以讀：" + readDirs.joined(separator: "、")) }
        return lines.joined(separator: "\n")
    }
}
