import Foundation

/// One run of a plugin service (experimental). Started without a shell, in the plugin's folder:
/// - responsible for itself (disclaimed), so macOS asks about it and grants it, not Cubi; without
///   the call that does this, it is not started at all rather than run with Cubi's permissions;
/// - every signal at its default and none blocked (Cubi ignores SIGPIPE, and an ignored signal
///   survives exec);
/// - leading its own process group, so stopping it reaches whatever it started;
/// - with no file descriptor of Cubi's but its three pipes.
public final class ServiceProcess: @unchecked Sendable {
    public typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// libsystem's `responsibility_spawnattrs_setdisclaim` (not public API), nil where it is missing.
    public static let systemDisclaim: Disclaim? =
        unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim"), to: Disclaim?.self)

    public enum StartError: Error, Equatable, LocalizedError {
        case noDisclaim
        case spawn(String)

        public var errorDescription: String? {
            switch self {
            case .noDisclaim: return "這個 macOS 沒辦法讓背景服務自己承擔權限，所以不啟動"
            case .spawn(let why): return "無法啟動：\(why)"
            }
        }
    }

    public let pid: pid_t
    /// Lines waiting for the service to read, at most this many bytes; past it `send` says no.
    public static let pendingLimit = 65_536
    /// Held for as long as the run lasts: a Pipe that goes away closes its ends, and the service
    /// would die of SIGPIPE at its first write.
    private let pipes: [Pipe]
    /// Its stdin, non-blocking: a service that stops reading must never hold up the caller (the main thread).
    private let inputFD: Int32
    private let lock = NSLock()
    private var ended = false
    private var inputClosed = false
    private var pending = Data()
    /// Waits for the pipe to take more; suspended while nothing is pending, cancelled only when the
    /// input closes (whose cancel handler closes the fd, as Dispatch requires).
    private var writer: DispatchSourceWrite?
    private var writerSuspended = false

    private init(pid: pid_t, pipes: [Pipe], inputFD: Int32) {
        self.pid = pid
        self.pipes = pipes
        self.inputFD = inputFD
    }

    /// `onExit` gets waitpid's status once the process has ended and its pipes have closed (or a
    /// second later, if something it left behind still holds them). Output arrives in chunks as written.
    public static func start(_ invocation: ToolPlugin.Invocation, environment: [String: String],
                             disclaim: Disclaim? = systemDisclaim,
                             onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void,
                             onExit: @escaping @Sendable (Int32) -> Void) throws -> ServiceProcess {
        guard let disclaim else { throw StartError.noDisclaim }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        guard disclaim(&attr, 1) == 0 else { throw StartError.noDisclaim }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addchdir_np(&actions, invocation.directory)

        let argv = ([invocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + env).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, invocation.executable, &actions, &attr, argv, env)
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        guard rc == 0 else { throw StartError.spawn(String(cString: strerror(rc))) }

        let child = pid
        // Its own copy of the write end, so nothing else closes it; EAGAIN instead of blocking,
        // EPIPE instead of SIGPIPE.
        let inputFD = dup(stdin.fileHandleForWriting.fileDescriptor)
        try? stdin.fileHandleForWriting.close()
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        let process = ServiceProcess(pid: child, pipes: [stdout, stderr], inputFD: inputFD)
        let pipes = DispatchGroup()
        for (pipe, deliver) in [(stdout, onStdout), (stderr, onStderr)] {
            pipes.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    pipes.leave()
                } else {
                    deliver(data)
                }
            }
        }
        Thread.detachNewThread {
            // Wait for the end without reaping: until it is reaped its pid, and so its group id,
            // cannot belong to anything else, so the kill below (and any in stop) hits only its group.
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            var status: Int32 = 0
            process.lock.lock()
            process.ended = true
            // Whatever it started is part of its group; nothing of it outlives the service.
            kill(-child, SIGKILL)
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            process.closeInput()
            process.lock.unlock()
            _ = pipes.wait(timeout: .now() + 1)
            onExit(status)
        }
        return process
    }

    public var hasEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    /// One line on its stdin, never blocking. What the pipe does not take waits in a buffer and goes
    /// in as the service reads; a line is never cut. False when it is gone or has left
    /// `pendingLimit` bytes unread: that line is dropped.
    @discardableResult
    public func send(_ line: String) -> Bool {
        let data = Data(line.utf8)
        lock.lock(); defer { lock.unlock() }
        guard !inputClosed else { return false }
        if !pending.isEmpty {
            guard pending.count + data.count <= Self.pendingLimit else { return false }
            pending.append(data)
            return true
        }
        let n = data.withUnsafeBytes { write(inputFD, $0.baseAddress, $0.count) }
        if n == data.count { return true }
        if n < 0 && errno != EAGAIN { return false }
        // Part of the line may be in: the rest has to follow, whatever the buffer holds.
        pending = Data(data.dropFirst(max(n, 0)))
        if let writer {
            if writerSuspended { writer.resume(); writerSuspended = false }
        } else {
            let source = DispatchSource.makeWriteSource(fileDescriptor: inputFD, queue: .global())
            source.setEventHandler { [weak self] in self?.flush() }
            writer = source
            source.resume()
        }
        return true
    }

    private func flush() {
        lock.lock(); defer { lock.unlock() }
        guard !inputClosed else { return }
        if !pending.isEmpty {
            let n = pending.withUnsafeBytes { write(inputFD, $0.baseAddress, $0.count) }
            if n > 0 { pending.removeFirst(n) }
            if n < 0 && errno != EAGAIN { pending.removeAll() }
        }
        // Nothing left: stop listening, or a writable pipe would wake this for ever.
        if pending.isEmpty, let writer, !writerSuspended {
            writer.suspend()
            writerSuspended = true
        }
    }

    /// With the lock held.
    private func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        pending.removeAll()
        let fd = inputFD
        if let writer {
            writer.setCancelHandler { close(fd) }
            // A suspended source does not run its cancel handler until it is resumed.
            if writerSuspended { writer.resume(); writerSuspended = false }
            writer.cancel()
            self.writer = nil
        } else {
            close(fd)
        }
    }

    /// Closes its stdin (the service's cue to end), then after `grace` sends SIGTERM to its group,
    /// and after another `grace` SIGKILL.
    public func stop(grace: TimeInterval = 2) {
        lock.lock(); closeInput(); lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            guard signalIfRunning(SIGTERM) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                _ = signalIfRunning(SIGKILL)
            }
        }
    }

    /// For Cubi quitting, when nothing scheduled would run: stdin closed and SIGTERM to the group at
    /// once, then SIGKILL if it has not ended within `wait` seconds. Returns once it is done.
    public func stopNow(wait: TimeInterval = 1) {
        lock.lock(); closeInput(); lock.unlock()
        _ = signalIfRunning(SIGTERM)
        let deadline = Date().addingTimeInterval(wait)
        while !hasEnded && Date() < deadline { usleep(20_000) }
        _ = signalIfRunning(SIGKILL)
    }

    /// Signals its group unless it has ended, under the lock the reaper holds while reaping: the
    /// group id cannot have been reused when the signal goes.
    private func signalIfRunning(_ signal: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return false }
        kill(-pid, signal)
        return true
    }
}
