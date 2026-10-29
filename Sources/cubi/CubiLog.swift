import Foundation

/// Appends to ~/Library/Logs/cubi.log (and NSLog). Cheap enough for per-event lines; never for per-frame.
enum CubiLog {
    static let path = CubiPaths.home.path + "/Library/Logs/cubi.log"
    private static let queue = DispatchQueue(label: "cc.dotdot.cubi.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let maxBytes = 2_000_000

    static func write(_ message: String) {
        NSLog("cubi: %@", message)
        let line = formatter.string(from: Date()) + " " + message + "\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
                try? fm.removeItem(atPath: path)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
