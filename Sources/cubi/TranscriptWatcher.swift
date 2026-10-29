import Foundation

/// While a request waits on the island, Claude Code writes nothing to the session transcript.
/// The first new `"type":"user"` entry (a tool_result after an allow, or the interruption line
/// after a deny) means the user decided in the terminal, even when the hook is not cancelled.
struct TranscriptWatcher {
    let path: String
    private(set) var offset: UInt64

    init?(path: String?) {
        guard let path, let size = TranscriptWatcher.size(of: path) else { return nil }
        self.path = path
        self.offset = size
    }

    private static func size(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
    }

    /// True once a user-type entry has been appended since the watcher was created.
    mutating func userEntryAppended() -> Bool {
        guard let size = Self.size(of: path), size > offset,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"type\":\"user\"")
    }
}
