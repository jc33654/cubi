// cubi-hook — the relay Claude Code (or another agent) runs on every hook event.
//
// Darwin only: no Foundation, no JSON parsing. Cold start is a few milliseconds, which matters
// because the status line can fire several times a second while Claude streams.
//
// Usage (as written into settings.json by the app):
//   cubi-hook --agent claude-code --event PreToolUse [--tool AskUserQuestion] [--capture]
//   cubi-hook --agent claude-code statusline --then <previous statusLine command...>
//
// Behaviour:
//   * Reads all of stdin, wraps it in an envelope with terminal identity, sends it to the app's
//     unix socket. If the app is not running (ENOENT / ECONNREFUSED) it exits 0 with no output
//     within ~300 ms, so Claude Code is never blocked.
//   * Blocking events (PermissionRequest, PreToolUse+AskUserQuestion) wait up to 115 s for one
//     reply line and print it verbatim on stdout. EOF without a reply = no decision.
//   * Everything else is fire-and-forget.
//   * `statusline` forwards the JSON, then runs the previous statusLine command with the same
//     stdin and passes its stdout and exit code through.
//   * `--capture` appends the envelope to ~/Library/Application Support/cubi/capture/<agent>-<event>.jsonl
//     so real payloads can be recorded as test fixtures.

import Darwin

// MARK: - Small helpers

@inline(__always) func env(_ key: String) -> String? {
    guard let p = getenv(key) else { return nil }
    return String(cString: p)
}

func readAll(fd: Int32) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
        if n == 0 { break }
        if errno == EINTR { continue }
        break
    }
    return out
}

@discardableResult
func writeAll(fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n > 0 { off += n; continue }
        if n < 0 && errno == EINTR { continue }
        return false
    }
    return true
}

func monotonicMs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec / 1_000_000)
}

/// JSON string literal with escaping, including the quotes.
func jsonString(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 {
                let hex = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

func jsonOptional(_ s: String?) -> String { s.map(jsonString) ?? "null" }

/// mkdir -p with a fixed mode. Returns false on the first failure that is not EEXIST.
func makeDirs(_ path: String, mode: mode_t) -> Bool {
    var current = ""
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        current += "/" + part
        if mkdir(current, mode) != 0 && errno != EEXIST { return false }
    }
    return true
}

// MARK: - Terminal identity

/// The tty of the nearest ancestor that has one, walking pbi_ppid at most `maxDepth` levels.
func findAncestorTTY(maxDepth: Int = 8) -> String? {
    var pid = getppid()
    for _ in 0..<maxDepth {
        if pid <= 1 { break }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if got != size { break }
        if info.e_tdev != 0xFFFF_FFFF, let name = devname(dev_t(info.e_tdev), mode_t(S_IFCHR)) {
            return "/dev/" + String(cString: name)
        }
        pid = pid_t(info.pbi_ppid)
    }
    return nil
}

// MARK: - Arguments

struct Args {
    var agent = "claude-code"
    var event: String? = nil
    var tool: String? = nil
    var capture = false
    var statusline = false
    var thenCommand: String? = nil
}

func parseArgs() -> Args {
    var a = Args()
    var argv = CommandLine.arguments.dropFirst()
    while let arg = argv.first {
        argv = argv.dropFirst()
        switch arg {
        case "--agent":   a.agent = argv.first ?? a.agent; argv = argv.dropFirst()
        case "--event":   a.event = argv.first; argv = argv.dropFirst()
        case "--tool":    a.tool = argv.first; argv = argv.dropFirst()
        case "--capture": a.capture = true
        case "statusline": a.statusline = true; a.event = "statusline"
        case "--then":
            // The installer passes the previous command as one shell-quoted argument. Older
            // installs passed it bare, so anything left over is joined back on.
            a.thenCommand = argv.joined(separator: " ")
            argv = argv.dropFirst(argv.count)
        default: break
        }
    }
    return a
}

// MARK: - Paths

let home = env("HOME") ?? "/tmp"
let supportDir = home + "/Library/Application Support/cubi"
let socketPath = supportDir + "/cubi.sock"
let captureDir = supportDir + "/capture"

// MARK: - Envelope

func buildEnvelope(args: Args, payload: [UInt8]) -> [UInt8] {
    // Raw newlines never occur inside a JSON document except as insignificant whitespace,
    // so dropping them keeps the payload valid and makes the envelope a single line.
    var compact: [UInt8] = []
    compact.reserveCapacity(payload.count)
    for b in payload where b != 0x0A && b != 0x0D { compact.append(b) }
    let trimmed = compact.drop(while: { $0 == 0x20 || $0 == 0x09 })
    let payloadText = trimmed.isEmpty ? "null" : String(decoding: trimmed, as: UTF8.self)

    var s = "{\"v\":1"
    s += ",\"agent\":" + jsonString(args.agent)
    s += ",\"event\":" + jsonOptional(args.event)
    s += ",\"tool\":" + jsonOptional(args.tool)
    s += ",\"pid\":\(getpid()),\"ppid\":\(getppid())"
    s += ",\"client\":{"
    s += "\"term_program\":" + jsonOptional(env("TERM_PROGRAM"))
    s += ",\"bundle_id\":" + jsonOptional(env("__CFBundleIdentifier"))
    s += ",\"term_session_id\":" + jsonOptional(env("TERM_SESSION_ID"))
    s += ",\"tty\":" + jsonOptional(findAncestorTTY())
    s += "}"
    s += ",\"payload\":" + payloadText
    s += "}\n"
    return Array(s.utf8)
}

// MARK: - Capture

func capture(args: Args, envelope: [UInt8]) {
    guard makeDirs(captureDir, mode: 0o700) else { return }
    let name = args.agent + "-" + (args.event ?? "unknown") + (args.tool.map { "-" + $0 } ?? "") + ".jsonl"
    let fd = open(captureDir + "/" + name, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { return }
    writeAll(fd: fd, envelope)
    close(fd)
}

// MARK: - Socket

/// Connects with a 300 ms budget. Returns the fd, or nil when the app is not there.
func connectToApp(timeoutMs: Int64 = 300) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in pathBytes.enumerated() { raw[i] = b }
        raw[pathBytes.count] = 0
    }
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 {
        guard errno == EINPROGRESS else { close(fd); return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeoutMs)) > 0 else { close(fd); return nil }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { close(fd); return nil }
    }
    _ = fcntl(fd, F_SETFL, flags)
    return fd
}

/// Reads one reply line (or until EOF) within the deadline. Returns the bytes without the newline.
func readReply(fd: Int32, deadlineMs: Int64) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let remaining = deadlineMs - monotonicMs()
        if remaining <= 0 { break }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let p = poll(&pfd, 1, Int32(min(remaining, Int64(Int32.max))))
        if p == 0 { break }
        if p < 0 { if errno == EINTR { continue } else { break } }
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
        if let nl = out.firstIndex(of: 0x0A) { return Array(out[0..<nl]) }
    }
    return out
}

// MARK: - Status line chain

/// Runs the previous statusLine command with `stdin` fed in, passing stdout and exit code through.
func runPrevious(command: String, stdin input: [UInt8]) -> Never {
    var pipeFDs: [Int32] = [0, 0]
    guard pipe(&pipeFDs) == 0 else { exit(0) }
    let readEnd = pipeFDs[0], writeEnd = pipeFDs[1]

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
    posix_spawn_file_actions_addclose(&actions, readEnd)
    posix_spawn_file_actions_addclose(&actions, writeEnd)

    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
    var child: pid_t = 0
    let rc = posix_spawn(&child, "/bin/sh", &actions, nil, argv, environ)
    posix_spawn_file_actions_destroy(&actions)
    close(readEnd)
    guard rc == 0 else { close(writeEnd); exit(0) }

    // Writes may fail if the child exits early; that is fine.
    signal(SIGPIPE, SIG_IGN)
    writeAll(fd: writeEnd, input)
    close(writeEnd)
    var status: Int32 = 0
    while waitpid(child, &status, 0) < 0 && errno == EINTR {}
    if (status & 0x7F) == 0 { exit((status >> 8) & 0xFF) }
    exit(1)
}

// MARK: - Main

let args = parseArgs()
let payload = readAll(fd: 0)
let envelope = buildEnvelope(args: args, payload: payload)

if args.capture { capture(args: args, envelope: envelope) }

let isBlocking = args.event == "PermissionRequest"
    || (args.event == "PreToolUse" && args.tool == "AskUserQuestion")

if let fd = connectToApp() {
    if writeAll(fd: fd, envelope) {
        if isBlocking {
            let reply = readReply(fd: fd, deadlineMs: monotonicMs() + 115_000)
            if !reply.isEmpty {
                writeAll(fd: 1, reply + [0x0A])
            }
        } else {
            shutdown(fd, SHUT_WR)
        }
    }
    close(fd)
}

if args.statusline, let cmd = args.thenCommand, !cmd.isEmpty {
    runPrevious(command: cmd, stdin: payload)
}

exit(0)
