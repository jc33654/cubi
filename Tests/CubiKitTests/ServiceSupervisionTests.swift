import Testing
import Foundation
@testable import CubiKit

// Inputs: wait statuses from real processes (/usr/bin/true, /usr/bin/false, /bin/sleep ended by a
// signal); instants from ContinuousClock.now plus offsets; the policy's own constants; stderr bytes
// built from ServiceProtocol's limits and from ServiceTail.limit.

/// Spawns `argv` with every signal at its default and none blocked (a test host may ignore
/// SIGTERM, and an ignored signal is inherited), optionally sends `signal` once it runs, and
/// returns waitpid's status.
private func waitStatus(_ argv: [String], signal: Int32? = nil) -> Int32 {
    var pid: pid_t = 0
    let cargs = argv.map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var all = sigset_t(), none = sigset_t()
    sigfillset(&all); sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attr, &all)
    posix_spawnattr_setsigmask(&attr, &none)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    guard posix_spawn(&pid, argv[0], nil, &attr, cargs, environ) == 0 else { return -1 }
    if let signal { usleep(100_000); kill(pid, signal) }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return status
}

@Test func exitsAreReadFromRealWaitStatuses() {
    #expect(ServiceExit(waitStatus: waitStatus(["/usr/bin/true"])) == .code(0))
    #expect(ServiceExit(waitStatus: waitStatus(["/usr/bin/false"])) == .code(1))
    #expect(ServiceExit(waitStatus: waitStatus(["/bin/sleep", "5"], signal: SIGKILL)) == .signal(SIGKILL))
    #expect(ServiceExit(waitStatus: waitStatus(["/bin/sleep", "5"], signal: SIGTERM)) == .signal(SIGTERM))
}

@Test func exitZeroIsADeliberateStopAndARightAwayOneIsTold() {
    typealias P = ServiceRestartPolicy
    var policy = P(restart: .onFailure)
    let t0 = ContinuousClock.now
    #expect(policy.decide(.code(0), startedAt: t0, at: t0.advanced(by: P.quickExit - .milliseconds(1))) == .stoppedRightAway)
    #expect(policy.decide(.code(0), startedAt: t0, at: t0.advanced(by: P.quickExit)) == .stopped)
    // Not restarted either way, whatever the setting.
    var never = P(restart: .never)
    #expect(never.decide(.code(0), startedAt: t0, at: t0) == .stoppedRightAway)
}

@Test func failuresBackOffAndGiveUpWithinTheWindow() {
    typealias P = ServiceRestartPolicy
    var policy = P(restart: .onFailure)
    let t0 = ContinuousClock.now
    var got: [P.Decision] = []
    for i in 0..<P.maxFailures {
        let at = t0.advanced(by: .seconds(i))
        got.append(policy.decide(i.isMultiple(of: 2) ? .code(1) : .signal(SIGKILL), startedAt: at, at: at))
    }
    #expect(got == P.delays.prefix(P.maxFailures - 1).map { .restart(after: $0) } + [.gaveUp(failures: P.maxFailures)])

    // Failures further apart than the window never add up.
    var spread = P(restart: .onFailure)
    for i in 0..<(P.maxFailures * 2) {
        let at = t0.advanced(by: P.failureWindow * i)
        #expect(spread.decide(.code(1), startedAt: at, at: at) == .restart(after: P.delays[0]))
    }

    // The delay stops growing at the last one.
    var long = P(restart: .onFailure)
    var last: P.Decision?
    for i in 0..<P.delays.count + 2 {
        let at = t0.advanced(by: P.failureWindow / (P.delays.count + 3) * i)
        last = long.decide(.code(1), startedAt: at, at: at)
        if case .gaveUp = last { break }
    }
    #expect(last == .gaveUp(failures: P.maxFailures))

    // `never` does not restart; reset forgets the count.
    var never = P(restart: .never)
    #expect(never.decide(.code(2), startedAt: t0, at: t0) == .failed)
    var again = P(restart: .onFailure)
    for i in 0..<(P.maxFailures - 1) { _ = again.decide(.code(1), startedAt: t0, at: t0.advanced(by: .seconds(i))) }
    again.reset()
    #expect(again.decide(.code(1), startedAt: t0, at: t0.advanced(by: .seconds(P.maxFailures))) == .restart(after: P.delays[0]))
}

@Test func anEndCubiAskedForIsNeitherRestartedNorCounted() {
    typealias P = ServiceRestartPolicy
    var policy = P(restart: .onFailure)
    let t0 = ContinuousClock.now
    // Turning the switch off sends SIGTERM (and SIGKILL if need be): not a crash.
    for exit in [ServiceExit.signal(SIGTERM), .signal(SIGKILL), .code(0), .code(1)] {
        #expect(policy.decide(exit, startedAt: t0, at: t0, askedToStop: true) == .stoppedByCubi)
    }
    // None of those counted: the next real failure is the first.
    #expect(policy.decide(.signal(SIGTERM), startedAt: t0, at: t0) == .restart(after: P.delays[0]))
}

@Test func theTailKeepsTheLastBytesAndQuotesTheLastLine() {
    var tail = ServiceTail()
    #expect(tail.lastLine == nil)
    tail.append(Data("\n  \r\n".utf8))
    #expect(tail.lastLine == nil)
    // The last line with something in it; CR and spaces trimmed.
    tail.append(Data("first\r\nsecond\r\n\n".utf8))
    #expect(tail.lastLine == "second")
    // A control character in it (an ANSI escape) comes out escaped.
    tail.append(Data("x\u{1B}[31m\n".utf8))
    #expect(tail.lastLine == "x\\u{1b}[31m")
    // Never more than the limit, however much is written; only the end is kept.
    let flood = Data(repeating: 0x61, count: ServiceTail.limit * 3)
    tail.append(flood + Data("\nend".utf8))
    #expect(tail.lastLine == "end")
    // A long last line is cut to the log limit.
    tail.append(Data("\n".utf8) + Data(repeating: 0x62, count: ServiceProtocol.logLimit * 2))
    #expect(tail.lastLine == String(repeating: "b", count: ServiceProtocol.logLimit))
}

@Test func theTailNeverGrowsPastItsLimit() {
    var tail = ServiceTail()
    for _ in 0..<4 { tail.append(Data(repeating: 0x0a, count: ServiceTail.limit)) }
    tail.append(Data("last".utf8))
    #expect(tail.lastLine == "last")
    #expect(Mirror(reflecting: tail).children.compactMap { $0.value as? Data }.first?.count == ServiceTail.limit)
}

// F67-3 and the review of batch 67: over the rate limit, a line is read for a reply at most as many
// times as calls still wait; an answered call gives its read back.
@Test func overTheLimitRepliesAreReadNoMoreThanCallsWait() {
    var budget = ServiceReplyBudget()
    var read = budget.read()
    #expect(!read)
    for _ in 0..<3 { budget.called() }
    read = budget.read()
    #expect(read && budget.spare == 2)
    // Two answered in time, one still waiting: one read left, not two.
    budget.settled(waiting: 1)
    #expect(budget.spare == 1)
    let first = budget.read(), second = budget.read()
    #expect(first && !second)
    // Never more than wait, never below none.
    budget.settled(waiting: 5)
    #expect(budget.spare == 0)
    budget.called()
    budget.settled(waiting: 0)
    read = budget.read()
    #expect(!read)
}
