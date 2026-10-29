import Foundation

/// While a request waits on the island, Claude Code may still flush earlier entries to the
/// session transcript, so "the file grew" proves nothing. What proves a terminal decision is a
/// new entry about *this* tool call: its tool_result after an allow, or the interruption after a
/// deny, both of which name the tool_use_id.
public struct TranscriptWatcher: Sendable {
    public let path: String
    public private(set) var offset: UInt64

    public init?(path: String?) {
        guard let path, let size = TranscriptWatcher.size(of: path) else { return nil }
        self.path = path
        self.offset = size
    }

    private static func size(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
    }

    /// Reads what was appended since the last call. Returns true when it settles the call with
    /// `toolUseID`. Without an id, only an explicit user interruption counts.
    public mutating func settled(toolUseID: String?) -> Bool {
        guard let size = Self.size(of: path), size > offset,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return Self.settles(text, toolUseID: toolUseID)
    }

    public static func settles(_ appended: String, toolUseID: String?) -> Bool {
        if let id = toolUseID, !id.isEmpty, appended.contains("\"tool_use_id\":\"\(id)\"") { return true }
        return appended.contains("[Request interrupted by user")
    }
}
