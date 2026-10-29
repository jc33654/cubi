import Foundation

/// Where the app keeps its files. `$HOME` wins when set, like the relay's lookup, so a test can
/// point the CLI at a scratch home instead of the real ~/.claude.
enum CubiPaths {
    static let home: URL = {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
}
