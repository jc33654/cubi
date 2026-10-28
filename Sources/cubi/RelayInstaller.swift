import Foundation

/// Keeps a copy of the bundled relay at ~/.cubi/bin/cubi-hook. settings.json points there, so
/// the hook keeps working when the app bundle moves, and the path has no spaces to quote.
enum RelayInstaller {
    static var installedPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.cubi/bin/cubi-hook"
    }

    /// Copies the relay when missing or different. Returns the installed path, or nil on failure.
    @discardableResult
    static func ensureInstalled() -> String? {
        guard let source = Bundle.main.url(forAuxiliaryExecutable: "cubi-hook") else {
            NSLog("cubi: bundled cubi-hook not found")
            return nil
        }
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: installedPath)
        do {
            let fresh = try Data(contentsOf: source)
            if let current = try? Data(contentsOf: dest), current == fresh {
                return dest.path
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            // Write beside and rename, so a hook starting mid-copy never runs half a binary.
            let temp = dest.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
            try fresh.write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: temp, to: dest)
            NSLog("cubi: installed relay at \(dest.path)")
            return dest.path
        } catch {
            NSLog("cubi: relay install failed: \(error)")
            return nil
        }
    }
}
