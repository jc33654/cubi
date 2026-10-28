import Foundation
import CubiKit

/// One relay connection. For blocking events the relay keeps it open until we `reply`.
final class HookConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Sends one line (the relay prints it verbatim to Claude Code's stdout) and closes.
    func reply(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var bytes = Array(line.utf8)
        if bytes.last != 0x0A { bytes.append(0x0A) }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
        closed = true
        Darwin.close(fd)
    }

    /// Closes without a reply: "no decision", the terminal asks instead.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

/// Listens on the unix socket cubi-hook connects to. Same-UID peers only, one JSON line per
/// connection, 1 MiB cap. Parsing happens here; everything else happens on the main actor.
final class HookServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (HookEnvelope, HookConnection) -> Void
    typealias ClosedHandler = @MainActor @Sendable (HookConnection) -> Void

    static let maxLineBytes = 1 << 20

    let socketPath: String
    private let queue = DispatchQueue(label: "cc.dotdot.cubi.hookserver")
    private let handler: Handler
    private let onClientClosed: ClosedHandler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var readers: [Int32: (source: DispatchSourceRead, buffer: Data, connection: HookConnection, delivered: Bool)] = [:]

    static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/cubi/cubi.sock"
    }

    init(socketPath: String = HookServer.defaultSocketPath, handler: @escaping Handler, onClientClosed: @escaping ClosedHandler) {
        self.socketPath = socketPath
        self.handler = handler
        self.onClientClosed = onClientClosed
    }

    enum Failure: Error { case socket(String) }

    func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket(): \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.socket("path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); throw Failure.socket("bind(): \(errno)") }
        chmod(socketPath, 0o600)
        guard listen(fd, 64) == 0 else { Darwin.close(fd); throw Failure.socket("listen(): \(errno)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for (_, r) in readers { r.source.cancel(); r.connection.close() }
            readers.removeAll()
            if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
            unlink(socketPath)
        }
    }

    // MARK: - Queue-side

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN: nothing more to accept
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let connection = HookConnection(fd: client)
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            readers[client] = (source, Data(), connection, false)
            source.setEventHandler { [weak self] in self?.readPending(client) }
            source.setCancelHandler { [weak self] in
                self?.readers.removeValue(forKey: client)
            }
            source.resume()
        }
    }

    private func readPending(_ fd: Int32) {
        guard var entry = readers[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                entry.buffer.append(contentsOf: chunk[0..<n])
                if entry.buffer.count > Self.maxLineBytes {
                    finish(fd, entry, notify: false)
                    return
                }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { break }
            // EOF or error: the relay has gone (fire-and-forget done, or a blocking hook was cancelled).
            if !entry.delivered { deliver(fd, &entry) }
            finish(fd, entry, notify: entry.delivered)
            return
        }
        if !entry.delivered, entry.buffer.contains(0x0A) { deliver(fd, &entry) }
        readers[fd] = entry
    }

    private func deliver(_ fd: Int32, _ entry: inout (source: DispatchSourceRead, buffer: Data, connection: HookConnection, delivered: Bool)) {
        let line: Data
        if let nl = entry.buffer.firstIndex(of: 0x0A) {
            line = entry.buffer[entry.buffer.startIndex..<nl]
        } else {
            line = entry.buffer
        }
        entry.delivered = true
        guard !line.isEmpty else { return }
        do {
            let envelope = try HookEnvelope.parse(line)
            let connection = entry.connection
            Task { @MainActor [handler] in handler(envelope, connection) }
        } catch {
            NSLog("cubi: bad envelope (\(line.count) bytes): \(error)")
        }
    }

    private func finish(_ fd: Int32, _ entry: (source: DispatchSourceRead, buffer: Data, connection: HookConnection, delivered: Bool), notify: Bool) {
        entry.source.cancel()
        let connection = entry.connection
        let wasOpen = !connection.isClosed
        connection.close()
        if notify && wasOpen {
            Task { @MainActor [onClientClosed] in onClientClosed(connection) }
        }
    }
}
