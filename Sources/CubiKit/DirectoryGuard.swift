import Foundation

/// Where a Claude Code session may be opened or given extra reading: the 開新 session dialog,
/// `cubi --new-session` and a plugin's `session.new` all ask here. Not the home directory (nor
/// anything above it: /, /Users), nor a folder of keys and credentials (nor inside or above one).
/// Folders are compared by what they are (device and inode), not by how they are written, so
/// neither case (~/.SSH), symbolic links, nor the firmlink path (/System/Volumes/Data/Users/…)
/// gets past. The same rule as the sprint plugin's check_code_dir.
public enum DirectoryGuard {
    /// Under the home directory: keys and credentials.
    public static let privateFolders = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config/gcloud", ".config/atlassian", "Library/Keychains"]
    /// On a Mac every folder of the data volume also lives under this prefix, which realpath does
    /// not resolve: /System/Volumes/Data/Users/x/.ssh is ~/.ssh.
    public static let firmlinkRoot = "/System/Volumes/Data"

    public enum Refusal: Error, Equatable, Sendable {
        case missing(String)
        case guarded(String)

        public var message: String {
            switch self {
            case .missing(let path): return "找不到資料夾 \(path)"
            case .guarded(let path): return "不能在 \(path) 開 session：根目錄、家目錄（或它的上層）、放金鑰與憑證的資料夾（或它的裡面、上層）都不行。請選專案自己的資料夾"
            }
        }
    }

    /// nil: allowed. `homes` are the home directories to guard: the account's own, and the one
    /// `$HOME` names when it is another.
    public static func refusal(_ path: String, homes: [String] = defaultHomes) -> Refusal? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let real = realPath(expanded), isDirectory(real), let me = identity(real) else { return .missing(expanded) }
        var keys: Set<Identity> = []
        var guarded: [String] = []
        for home in homes {
            guard let realHome = realPath(home), isDirectory(realHome) else { continue }
            guarded.append(realHome)
            for folder in privateFolders {
                let p = realHome + "/" + folder
                if isDirectory(p), let id = identity(p) {
                    keys.insert(id)
                    guarded.append(p)
                }
            }
        }
        // Inside a folder of keys: the path or one of the folders above it is one.
        if upward(real).contains(where: { identity($0).map(keys.contains) ?? false }) { return .guarded(expanded) }
        // A guarded folder, or above one: the path is that folder or one of the folders above it.
        for folder in guarded {
            for way in [folder, firmlinkRoot + folder] where isDirectory(way) {
                if upward(way).contains(where: { identity($0) == me }) { return .guarded(expanded) }
            }
        }
        return nil
    }

    /// The account's home (from the user database, whatever `$HOME` says) and `$HOME`'s.
    public static var defaultHomes: [String] {
        var homes: [String] = []
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { homes.append(String(cString: dir)) }
        let env = NSHomeDirectory()
        if !homes.contains(env) { homes.append(env) }
        return homes
    }

    struct Identity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    static func identity(_ path: String) -> Identity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Identity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino))
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The path, its parent, … up to /.
    static func upward(_ path: String) -> [String] {
        var out = [path]
        var current = path
        while current != "/" {
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { break }
            out.append(current)
        }
        return out
    }
}
