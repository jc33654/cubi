import Foundation

/// How a plugin service ended, from `waitpid`'s status.
public enum ServiceExit: Sendable, Equatable {
    case code(Int32)
    case signal(Int32)

    public init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .code((status >> 8) & 0xff) : .signal(signal)
    }
}

/// What Cubi does after a plugin service exits (experimental). Exit 0 is a deliberate stop and is
/// never restarted; one that comes right after the start is shown, so a service does not vanish
/// without a word. Any other end is a failure: with `restart: on-failure` it is started again after
/// a growing delay, until too many failures fall in one window.
public struct ServiceRestartPolicy: Sendable {
    /// One per failure before giving up (`maxFailures` − 1 of them); the last repeats if there are more.
    public static let delays: [Duration] = [1, 2, 4, 8].map { .seconds($0) }
    public static let failureWindow: Duration = .seconds(600)
    public static let maxFailures = 5
    /// Ending sooner than this after the start counts as ending right away.
    public static let quickExit: Duration = .seconds(10)

    public enum Decision: Sendable, Equatable {
        /// Cubi asked it to end (switch or plugin off, a reload, Cubi quitting): whatever the exit, not a failure.
        case stoppedByCubi
        case restart(after: Duration)
        case stopped
        case stoppedRightAway
        /// Failed, and `restart: never`.
        case failed
        /// Failed `maxFailures` times within `failureWindow`: Cubi stops trying until the user does something.
        case gaveUp(failures: Int)
    }

    private let restart: ToolPlugin.Restart
    private var failures: [ContinuousClock.Instant] = []

    public init(restart: ToolPlugin.Restart) { self.restart = restart }

    public mutating func decide(_ exit: ServiceExit, startedAt start: ContinuousClock.Instant, at now: ContinuousClock.Instant,
                                askedToStop: Bool = false) -> Decision {
        // Its SIGTERM looks like a crash; it is not one, and is not counted.
        if askedToStop { return .stoppedByCubi }
        if exit == .code(0) {
            return start.duration(to: now) < Self.quickExit ? .stoppedRightAway : .stopped
        }
        guard restart == .onFailure else { return .failed }
        failures.removeAll { $0.duration(to: now) >= Self.failureWindow }
        failures.append(now)
        guard failures.count < Self.maxFailures else { return .gaveUp(failures: failures.count) }
        return .restart(after: Self.delays[min(failures.count - 1, Self.delays.count - 1)])
    }

    /// A fresh start chosen by the user (switch turned on again, plugins reloaded).
    public mutating func reset() { failures.removeAll() }
}

/// The last bytes a service wrote to stderr: kept for the settings page and the log when it ends,
/// never more than `limit` bytes however much it writes.
public struct ServiceTail: Sendable {
    public static let limit = 8192
    private var bytes = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > Self.limit { bytes = Data(bytes.suffix(Self.limit)) }
    }

    /// The last line with something in it, quoted like the service's other words (`ServiceProtocol.quoted`).
    public var lastLine: String? {
        let lines = bytes.split(separator: 0x0a).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.last { !$0.isEmpty }.map { ServiceProtocol.quoted($0, limit: ServiceProtocol.logLimit) }
    }
}

/// How many lines over the rate limit may still be read for a `reply`: never more than calls still
/// waiting, and each read uses one up, so a service that floods while a call waits is read at most
/// that many times.
public struct ServiceReplyBudget: Sendable, Equatable {
    public private(set) var spare = 0

    public init() {}

    /// A call went out.
    public mutating func called() { spare += 1 }

    /// Whether one more line over the limit may be read; uses one up if so.
    public mutating func read() -> Bool {
        guard spare > 0 else { return false }
        spare -= 1
        return true
    }

    /// A call was answered or ended, `waiting` still wait.
    public mutating func settled(waiting: Int) { spare = min(spare, waiting) }
}

/// At most `count` per `window`, the window sliding. Monotonic time, so setting the clock back
/// (by hand or NTP) does not hold a service's output up.
public struct ServiceRateLimit: Sendable {
    private let count: Int
    private let window: Duration
    private var times: [ContinuousClock.Instant] = []

    public init(count: Int, per window: Duration) {
        self.count = count
        self.window = window
    }

    public mutating func allow(at now: ContinuousClock.Instant) -> Bool {
        times.removeAll { $0.duration(to: now) >= window }
        guard times.count < count else { return false }
        times.append(now)
        return true
    }
}

/// Splits a stream into lines. A line longer than the limit is dropped whole, its size reported
/// once it ends, and memory stays bounded while it goes on.
public struct ServiceLineReader: Sendable {
    public enum Item: Sendable, Equatable {
        case line(Data)
        case dropped(Int)
    }

    private var buffer = Data()
    private var overflow: Int?
    private let limit: Int

    public init(limit: Int = ServiceProtocol.lineLimit) { self.limit = limit }

    public mutating func push(_ bytes: Data) -> [Item] {
        var out: [Item] = []
        var rest = bytes[...]
        while let nl = rest.firstIndex(of: 0x0a) {
            let piece = rest[rest.startIndex..<nl]
            rest = rest[rest.index(after: nl)...]
            if let skipped = overflow {
                out.append(.dropped(skipped + piece.count))
                overflow = nil
            } else if buffer.count + piece.count > limit {
                out.append(.dropped(buffer.count + piece.count))
            } else {
                out.append(.line(buffer + piece))
            }
            buffer = Data()
        }
        if let skipped = overflow {
            overflow = skipped + rest.count
        } else if buffer.count + rest.count > limit {
            overflow = buffer.count + rest.count
            buffer = Data()
        } else {
            buffer.append(contentsOf: rest)
        }
        return out
    }

    /// At the end of the stream: what is left without a newline is the last line (dropped if it
    /// was too long), so a service that prints and exits does not lose it.
    public mutating func finish() -> [Item] {
        defer { buffer = Data(); overflow = nil }
        if let skipped = overflow { return [.dropped(skipped)] }
        return buffer.isEmpty ? [] : [.line(buffer)]
    }
}
