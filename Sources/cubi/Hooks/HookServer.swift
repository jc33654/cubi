import Foundation
import CubiKit

/// One relay connection. For blocking events the relay keeps it open until we `reply`.
///
/// The file descriptor is owned by the server's DispatchSource: closing it here while the source
/// is live would let the kernel hand the same number to the next connection, whose bytes would
/// then go to the stale source. So `reply`/`close` only ask the server to cancel the source, and
/// the source's cancel handler is the one place the fd is closed.
final class HookConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private let teardown: @Sendable () -> Void

    init(fd: Int32, teardown: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.teardown = teardown
    }

    /// Sends one line (the relay prints it verbatim to Claude Code's stdout) and closes.
    func reply(_ line: String) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        var bytes = Array(line.utf8)
        if bytes.last != 0x0A { bytes.append(0x0A) }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
        lock.unlock()
        teardown()
    }

    /// Closes without a reply: "no decision", the terminal asks instead.
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        teardown()
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

    private final class Reader {
        let source: DispatchSourceRead
        let connection: HookConnection
        var buffer = Data()
        var delivered = false
        init(source: DispatchSourceRead, connection: HookConnection) {
            self.source = source
            self.connection = connection
        }
    }
    private var readers: [Int32: Reader] = [:]

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
            for (_, r) in readers { r.source.cancel() }
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

            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            let connection = HookConnection(fd: client) { [queue] in
                queue.async { source.cancel() }
            }
            let reader = Reader(source: source, connection: connection)
            readers[client] = reader
            source.setEventHandler { [weak self] in self?.readPending(client) }
            // The only place the fd is closed. Cancelling twice is harmless.
            source.setCancelHandler { [weak self] in
                Darwin.close(client)
                self?.readers.removeValue(forKey: client)
            }
            source.resume()
        }
    }

    private func readPending(_ fd: Int32) {
        guard let reader = readers[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                reader.buffer.append(contentsOf: chunk[0..<n])
                if reader.buffer.count > Self.maxLineBytes {
                    CubiLog.write("envelope over \(Self.maxLineBytes) bytes dropped")
                    reader.connection.close()
                    return
                }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { break }
            // EOF or error: the relay has gone (fire-and-forget done, or a blocking hook was cancelled).
            if !reader.delivered { deliver(reader) }
            let wasOpen = !reader.connection.isClosed
            reader.connection.close()
            if wasOpen && reader.delivered {
                let connection = reader.connection
                Task { @MainActor [onClientClosed] in onClientClosed(connection) }
            }
            return
        }
        if !reader.delivered, reader.buffer.contains(0x0A) { deliver(reader) }
    }

    private func deliver(_ reader: Reader) {
        reader.delivered = true
        let line: Data
        if let nl = reader.buffer.firstIndex(of: 0x0A) {
            line = reader.buffer[reader.buffer.startIndex..<nl]
        } else {
            line = reader.buffer
        }
        guard !line.isEmpty else { return }
        do {
            let envelope = try HookEnvelope.parse(line)
            let connection = reader.connection
            Task { @MainActor [handler] in handler(envelope, connection) }
        } catch {
            CubiLog.write("bad envelope (\(line.count) bytes): \(error)")
            reader.connection.close()
        }
    }
}
