import Testing
import Foundation
@testable import CubiKit

// Inputs: real processes (/bin/cat, /bin/pwd, /bin/sh, /bin/zsh, /usr/bin/yes, /usr/bin/python3)
// started through ServiceProcess, and what they print. The only constants are the signal numbers
// and zsh's 128+signal exit convention for a pipeline member killed by a signal.

/// Collects what a run prints and how it ends.
private final class Run: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private var status: Int32?
    private let ended = DispatchSemaphore(value: 0)

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    func add(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func addErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func end(_ s: Int32) { lock.lock(); status = s; lock.unlock(); ended.signal() }
    /// waitpid's status, or nil if it did not end within `seconds`.
    func exit(within seconds: Double) -> ServiceExit? {
        guard ended.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return status.map(ServiceExit.init(waitStatus:))
    }
    /// Waits until stdout has a full line.
    func firstLine(within seconds: Double) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let line = stdout.split(separator: "\n").first, stdout.contains("\n") { return String(line) }
            usleep(10_000)
        }
        return nil
    }
}

private func start(_ argv: [String], in dir: String = FileManager.default.temporaryDirectory.path,
                   disclaim: ServiceProcess.Disclaim? = ServiceProcess.systemDisclaim) throws -> (ServiceProcess, Run) {
    let run = Run()
    let p = try ServiceProcess.start(ToolPlugin.Invocation(executable: argv[0], arguments: Array(argv.dropFirst()), stdin: nil, reveal: false, directory: dir),
                                     environment: ProcessInfo.processInfo.environment, disclaim: disclaim,
                                     onStdout: run.add, onStderr: run.addErr, onExit: run.end)
    return (p, run)
}

@Test func itIsResponsibleForItselfAndRunsInThePluginFolder() throws {
    let script = "import ctypes,os; f=ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid; f.restype=ctypes.c_int; f.argtypes=[ctypes.c_int]; print(os.getpid(), f(os.getpid()))"
    let (_, run) = try start(["/usr/bin/python3", "-I", "-c", script])
    #expect(run.exit(within: 20) == .code(0))
    let pids = run.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    #expect(pids.count == 2 && pids[0] == pids[1] && pids[0] != getpid())

    // realpath(3), as pwd -P resolves it (Foundation's resolvingSymlinksInPath drops /private).
    let resolved = realpath(FileManager.default.temporaryDirectory.path, nil)
    defer { free(resolved) }
    let dir = String(cString: resolved!)
    let (_, pwd) = try start(["/bin/pwd", "-P"], in: dir)
    #expect(pwd.exit(within: 5) == .code(0))
    #expect(pwd.stdout == dir + "\n")
}

@Test func withoutTheDisclaimCallNothingStarts() {
    #expect(throws: ServiceProcess.StartError.noDisclaim) { try start(["/bin/cat"], disclaim: nil) }
}

@Test func signalsAreBackAtTheirDefaultsEvenWhenCubiIgnoresSIGPIPE() throws {
    // As Cubi's main.swift does.
    signal(SIGPIPE, SIG_IGN)
    // `yes` writing into a pipe whose reader is gone: killed by SIGPIPE (zsh reports 128+13), unless
    // SIGPIPE came in ignored, when it gets EPIPE and exits 1.
    let check = ["/bin/zsh", "-fc", "yes | head -c 1 >/dev/null; print $pipestatus[1]"]
    let (_, run) = try start(check)
    #expect(run.exit(within: 10) == .code(0))
    #expect(run.stdout == "\(128 + SIGPIPE)\n")

    // The same without the reset: the ignored SIGPIPE comes through. This is what the reset is for.
    var pid: pid_t = 0
    let pipe = Pipe()
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 1)
    let argv = check.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    #expect(posix_spawn(&pid, check[0], &actions, nil, argv, environ) == 0)
    try pipe.fileHandleForWriting.close()
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "1\n")
}

@Test func closingStdinIsTheCueAndALineGoesIn() throws {
    let (p, run) = try start(["/bin/cat"])
    #expect(p.send("hello\n"))
    #expect(run.firstLine(within: 5) == "hello")
    p.stop(grace: 5)
    // cat ends at EOF, well before any signal.
    #expect(run.exit(within: 3) == .code(0))
    #expect(p.hasEnded)
    #expect(!p.send("late\n"))
}

// F64-1 (review of batch 64): a service that never reads its stdin must not hold up the sender.
// The line is what Cubi sends back for `present`; 65 536 is the pipe size the reviewer's probe filled.
@Test func sendingNeverBlocksWhenTheServiceDoesNotRead() throws {
    let (p, run) = try start(["/bin/sleep", "20"])
    let line = ServiceProtocol.presented(id: 0, failure: "unavailable")
    let began = Date()
    let taken = (0..<5000).map { _ in p.send(line) }
    #expect(Date().timeIntervalSince(began) < 1)
    #expect(taken.first == true)
    #expect(taken.last == false)
    // Whole lines only, and no more than the pipe and the buffer hold.
    let accepted = taken.firstIndex(of: false) ?? taken.count
    #expect(taken[accepted...].allSatisfy { !$0 })
    #expect(accepted * line.utf8.count <= 65_536 + ServiceProcess.pendingLimit + line.utf8.count)
    p.stopNow(wait: 0.3)
    #expect(run.exit(within: 5) != nil)
}

// F64-1: a service that reads slowly gets every line it was sent, whole and in order.
@Test func aSlowReaderGetsEveryAcceptedLineWholeAndInOrder() throws {
    // Reads nothing for half a second after the first line of each round (ids 0 and 10000), so both
    // rounds fill the pipe and the second needs the suspended writer back.
    let (p, run) = try start(["/bin/sh", "-c", "while IFS= read -r l; do printf '%s\\n' \"$l\"; case \"$l\" in *'\"id\":0,'*|*'\"id\":10000,'*) sleep 0.5;; esac; done; exit 0"])
    var all = ""
    // Two rounds: the second needs the writer back after it went quiet.
    for round in 0..<2 {
        let lines = (0..<2500).map { ServiceProtocol.call(id: round * 10_000 + $0, action: "send", args: nil) }
        let accepted = lines.filter { p.send($0) }
        // More than the pipe holds: some of it went through the pending buffer.
        #expect(accepted.joined().utf8.count > 65_536)
        all += accepted.joined()
        // Everything accepted reaches it in time (stop drops what is still waiting, so wait first).
        let deadline = Date().addingTimeInterval(15)
        while run.stdout.utf8.count < all.utf8.count && Date() < deadline { usleep(50_000) }
        #expect(run.stdout == all)
    }
    p.stop(grace: 5)
    #expect(run.exit(within: 10) == .code(0))
}

@Test func aServiceThatIgnoresSIGTERMIsKilled() throws {
    let (p, run) = try start(["/bin/sh", "-c", "trap '' TERM; echo ready; while :; do sleep 1; done"])
    #expect(run.firstLine(within: 5) == "ready")
    p.stop(grace: 0.3)
    #expect(run.exit(within: 5) == .signal(SIGKILL))
}

@Test func stoppingNowKillsWhatDoesNotEndInTime() throws {
    let (p, run) = try start(["/bin/sh", "-c", "trap '' TERM; echo ready; while :; do sleep 1; done"])
    #expect(run.firstLine(within: 5) == "ready")
    let began = Date()
    p.stopNow(wait: 0.3)
    #expect(Date().timeIntervalSince(began) < 2)
    #expect(run.exit(within: 5) == .signal(SIGKILL))
}

@Test func nothingItStartedOutlivesIt() throws {
    func gone(_ pid: pid_t, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(20_000)
        }
        return false
    }
    // Stopped by Cubi while a child of it runs.
    let (p, run) = try start(["/bin/sh", "-c", "sleep 30 & echo $!; wait"])
    let child = run.firstLine(within: 5).flatMap { Int32($0) }
    #expect(child != nil)
    p.stop(grace: 0.3)
    #expect(run.exit(within: 5) != nil)
    #expect(gone(child ?? 0, within: 3))

    // Ending on its own while a child of it runs.
    let (_, quick) = try start(["/bin/sh", "-c", "sleep 30 & echo $!"])
    let orphan = quick.firstLine(within: 5).flatMap { Int32($0) }
    #expect(quick.exit(within: 5) == .code(0))
    #expect(gone(orphan ?? 0, within: 3))
}
