import Foundation

/// The Claude desktop app's own session records: one `local_<id>.json` per conversation under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`, carrying the
/// Claude Code session id it runs (`cliSessionId`). That `local_` id is what the app's
/// `claude://code/continue?session=` deep link takes, so this is how a click on a session that
/// runs inside the app lands on the right conversation. Read only; Cubi never writes here.
/// Not a public API: when the app changes its files or its link, the lookup just finds nothing.
/// The records are big (hundreds of KB each: they carry UI snapshots), so callers read off the
/// main thread.
public enum ClaudeDesktopSessions {
    public struct Entry: Sendable, Equatable {
        public var localID: String
        public var cliSessionID: String
        /// Milliseconds since 1970, as the app writes it: when the user last looked at it.
        public var lastFocusedAt: Double

        public init(localID: String, cliSessionID: String, lastFocusedAt: Double = 0) {
            self.localID = localID; self.cliSessionID = cliSessionID; self.lastFocusedAt = lastFocusedAt
        }
    }

    /// Only the fields Cubi needs; the rest of the record is skipped by the decoder.
    private struct Record: Decodable {
        var sessionId: String
        var cliSessionId: String?
        var isArchived: Bool?
        var lastFocusedAt: Double?
    }

    public static func directory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Every live record at `<account>/<org>/local_*.json`; archived conversations and other JSON are skipped.
    public static func entries(in directory: URL) -> [Entry] {
        func children(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        return children(directory).flatMap(children).flatMap(children)
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }.compactMap(parse)
    }

    /// The live app conversation running `cliSessionID`: the one looked at most recently when a
    /// Claude Code session was resumed into more than one.
    public static func entry(for cliSessionID: String, in entries: [Entry]) -> Entry? {
        entries.filter { $0.cliSessionID == cliSessionID }.max { $0.lastFocusedAt < $1.lastFocusedAt }
    }

    /// The link that brings the app to the front on that conversation; nil for an id the app
    /// would refuse anyway (its own check), so a stray character in a record cannot bend the link.
    public static func continueLink(_ localID: String) -> URL? {
        guard localID.wholeMatch(of: /local_[A-Za-z0-9-]{1,64}/) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(localID)")
    }

    static func parse(_ data: Data) -> Entry? {
        guard let r = try? JSONDecoder().decode(Record.self, from: data), r.isArchived != true,
              let cli = r.cliSessionId, !cli.isEmpty else { return nil }
        return Entry(localID: r.sessionId, cliSessionID: cli, lastFocusedAt: r.lastFocusedAt ?? 0)
    }
}
