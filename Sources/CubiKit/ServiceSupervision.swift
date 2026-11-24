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
