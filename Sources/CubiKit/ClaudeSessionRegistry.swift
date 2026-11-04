import Foundation

/// Claude Code's own list of running sessions: one `~/.claude/sessions/<pid>.json` per process,
/// with the session id and its current name. A rename lands here (and in the terminal tab title)
/// immediately, while the hooks only learn it from the next status line, so this is the freshest
/// name Cubi can get. Read only; Cubi never writes here.
public enum ClaudeSessionRegistry {
    public struct Entry: Sendable, Equatable {
        public var sessionID: String
        public var name: String?
        /// Claude Code's `nameSource`: `user` for a /rename, `derived` for a name it made up
        /// (like `proj-32`), absent in older versions.
        public var source: String?
        /// Milliseconds since 1970, as Claude Code writes it.
        public var updatedAt: Double

        public init(sessionID: String, name: String?, source: String? = nil, updatedAt: Double) {
            self.sessionID = sessionID; self.name = name; self.source = source; self.updatedAt = updatedAt
        }

        /// The name only when the user chose it. A derived name is not what the terminal tab
        /// shows (that follows the status line) and must not replace a better name Cubi has.
        public var userName: String? { source == "user" ? name : nil }
    }

    public static func directory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions")
    }

    /// Every readable entry; files that are not a session (other JSON, keys) are skipped.
    public static func entries(in directory: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }.compactMap(parse)
    }

    public static func entry(for sessionID: String, in directory: URL) -> Entry? {
        entry(for: sessionID, in: entries(in: directory))
    }

    /// When a session id appears twice (a resumed session under a new process), the most
    /// recently updated one wins.
    public static func entry(for sessionID: String, in entries: [Entry]) -> Entry? {
        entries.filter { $0.sessionID == sessionID }.max { $0.updatedAt < $1.updatedAt }
    }

    static func parse(_ data: Data) -> Entry? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let id = value["sessionId"]?.string, !id.isEmpty else { return nil }
        let name = value["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return Entry(sessionID: id, name: name, source: value["nameSource"]?.string, updatedAt: value["updatedAt"]?.double ?? 0)
    }
}
