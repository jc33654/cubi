import Foundation

/// What a tool plugin's panel asks for with the built-in `session.new`: read from the JSON it
/// sends, checked, and worded for the question the user answers before anything opens.
public struct SessionNewSpec: Equatable, Sendable {
    public var directory: String
    public var prompt: String?
    public var restricted: Bool
    public var readDirs: [String]

    public static let fields: Set<String> = ["directory", "prompt", "restricted", "readDirs"]
    public static let maxReadDirs = 8
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

        public var message: String {
            switch self {
            case .shape: return "session.new 要 args[0] 是 {\"directory\", \"prompt\"} 的 JSON"
            case .unknownField(let name): return "session.new 不認得欄位「\(name)」（只收 directory、prompt、restricted、readDirs）"
            case .noDirectory(let path): return "找不到目錄 \(path)"
            case .restrictedNotBool: return "session.new 的 restricted 要是 true 或 false"
            case .readDirsShape: return "session.new 的 readDirs 要是目錄路徑的陣列"
            case .readDirsWithoutRestricted: return "session.new 的 readDirs 只能跟 restricted: true 一起用"
            case .tooManyReadDirs: return "session.new 的 readDirs 最多 \(maxReadDirs) 個"
            case .noReadDir(let path): return "找不到 readDirs 的目錄 \(path)"
            case .privateReadDir(let path): return "readDirs 不能是 \(path)（家目錄本身、根目錄，或放金鑰與憑證的目錄）"
            }
        }
    }

    /// `isDirectory` answers for an absolute, standardized path. A field the spec does not know
    /// is refused: a plugin can ask for the restricted mode, never pass flags of its own.
    /// `home` is the user's home directory: it, the root, and the places keys and credentials
    /// live under it are never handed to a session as extra reading, whatever the question shows.
    public static func parse(_ raw: String?, promptLimit: Int, home: String = NSHomeDirectory(), isDirectory: (String) -> Bool) throws -> SessionNewSpec {
        guard let raw, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)), let object = value.object,
              let dir = object["directory"]?.string, !dir.isEmpty else { throw ParseError.shape }
        if let extra = object.keys.filter({ !fields.contains($0) }).sorted().first { throw ParseError.unknownField(extra) }
        let home = absolute(home, home: home)
        let directory = absolute(dir, home: home)
        guard directory.hasPrefix("/"), isDirectory(directory) else { throw ParseError.noDirectory(directory) }
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
                guard !isPrivate(path, home: home) else { throw ParseError.privateReadDir(path) }
                if !readDirs.contains(path) { readDirs.append(path) }
            }
        default: throw ParseError.readDirsShape
        }
        return SessionNewSpec(directory: directory, prompt: prompt, restricted: restricted, readDirs: readDirs)
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

    /// The body of the question. `hooksInstalled`: whether the session's approvals will come up on
    /// the island (with Cubi's hooks) or only in the terminal.
    public func confirmation(hooksInstalled: Bool) -> String {
        let shown = prompt.map { $0.count > Self.shownPrompt ? $0.prefix(Self.shownPrompt) + "…（共 \($0.count) 字）" : $0 } ?? "（沒有）"
        var lines = ["目錄：\(directory)", "要交給 Claude 的話：\(shown)"]
        guard restricted else { return lines.joined(separator: "\n") }
        lines.append("受限模式：不套用你的允許規則，每條指令都要你核准。")
        if !readDirs.isEmpty { lines.append("另外可以讀：" + readDirs.joined(separator: "、")) }
        lines.append(hooksInstalled
            ? "島上的審批卡不會有「總是允許」；改到終端處理審批時，Claude Code 自己的「一律允許」會讓這個 session 之後不再問。"
            : "未安裝 Cubi hooks：審批會出現在終端裡。在那裡選 Claude Code 的「一律允許」的話，這個 session 之後就不再問。")
        return lines.joined(separator: "\n")
    }
}
