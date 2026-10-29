import Foundation

/// Reads and rewrites a settings file Cubi does not own (~/.claude/settings.json).
/// Rules (after Coucou's ClaudeSettingsFile, MIT): never treat an unreadable or invalid file as
/// empty, always take a dated backup, and only write over the exact bytes that were shown.
public enum SettingsFile {
    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable(String)
        case invalid(String)
        case changedSincePreview(String)
        case backupFailed(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let n): return "\(n) 無法讀取，沒有動它。"
            case .invalid(let n): return "\(n) 不是合法的 JSON，沒有動它。"
            case .changedSincePreview(let n): return "\(n) 在預覽之後被改過了，沒有寫入，請重新預覽。"
            case .backupFailed(let n): return "無法備份 \(n)，沒有寫入。"
            case .writeFailed(let n): return "無法寫入 \(n)，原檔未動。"
            }
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var object: JSONValue
        /// The bytes the object was parsed from; nil when the file does not exist.
        public var bytes: Data?
    }

    /// Absent → empty object. Whitespace-only → empty object. Anything else must parse to an object.
    public static func read(at url: URL) throws -> Snapshot {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot(object: .object([:]), bytes: nil) }
        guard let bytes = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            return Snapshot(object: .object([:]), bytes: bytes)
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: bytes), case .object = value else {
            throw Failure.invalid(name)
        }
        return Snapshot(object: value, bytes: bytes)
    }

    public static func serialize(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        if data.last != 0x0A { data.append(0x0A) }
        return data
    }

    /// Writes `data` over `url` only if the file still holds `original`. Backs up first into
    /// `backupDir`, writes beside and renames. Returns the backup URL (nil when there was no file).
    @discardableResult
    public static func write(_ data: Data, to url: URL, expecting original: Data?, backupDir: URL) throws -> URL? {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let exists = fm.fileExists(atPath: url.path)
        var current: Data? = nil
        if exists {
            guard let bytes = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
            current = bytes
        }
        guard current == original else { throw Failure.changedSincePreview(name) }

        let target = url.resolvingSymlinksInPath()
        var backup: URL? = nil
        var mode = 0o600
        if exists {
            do {
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let dest = freeBackupURL(in: backupDir, for: name)
                try fm.copyItem(at: target, to: dest)
                backup = dest
            } catch { throw Failure.backupFailed(name) }
            if let found = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
                mode = found.intValue & 0o777
            }
        } else {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(name).cubi-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: temp)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw Failure.writeFailed(name)
        }
        do { try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: temp.path) } catch {
            try? fm.removeItem(at: temp)
            throw Failure.writeFailed(name)
        }
        guard rename(temp.path, target.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw Failure.writeFailed(name)
        }
        return backup
    }

    static func freeBackupURL(in dir: URL, for name: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(name).bak-\(f.string(from: Date()))"
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }
}
