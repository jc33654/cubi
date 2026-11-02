import Foundation
import CubiKit

/// Directories offered when starting a new session: the ones started from Cubi (most recent first,
/// kept in UserDefaults), then whatever Claude Code itself has recorded in ~/.claude.json.
/// Only directories that still exist are offered.
@MainActor
final class RecentProjects {
    static let key = "recentProjects"
    static let limit = 20

    var paths: [String] {
        let noted = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        var seen = Set<String>()
        return (noted + Self.claudeProjects().filter { !noted.contains($0) }.sorted()).filter { path in
            seen.insert(path).inserted && FileManager.default.fileExists(atPath: path)
        }
    }

    func note(_ directory: String) {
        var noted = (UserDefaults.standard.stringArray(forKey: Self.key) ?? []).filter { $0 != directory }
        noted.insert(directory, at: 0)
        UserDefaults.standard.set(Array(noted.prefix(Self.limit)), forKey: Self.key)
    }

    /// Keys of `projects` in ~/.claude.json are real paths. Claude Code's own state under ~/.claude
    /// is not a project anyone wants to open. Unreadable or unexpected: an empty list, no error.
    private static func claudeProjects() -> [String] {
        let home = CubiPaths.home
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return [] }
        let claudeDir = home.appendingPathComponent(".claude").path
        return projects.keys.filter { !$0.hasPrefix(claudeDir) }
    }
}
