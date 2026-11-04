import Foundation
import CubiKit

/// Runs a checked invocation without a shell, in the plugin's directory. stdin feeds long bodies
/// (too long for argv). With a `timeout`, a command still running at the deadline gets SIGKILL.
/// The pipes are read to EOF, so a background grandchild that outlives its parent and keeps stdout
/// open keeps us waiting: hook commands must not leave children behind (documented).
enum ToolRunner {
    struct Result: Sendable {
        var out: String
        var err: String
        var code: Int32
    }

    static let hookTimeout: TimeInterval = 20
    /// More than this on stdout is cut; no caller wants it (PluginIO stops at 64 KB).
    static let outputLimit = 4 << 20

    /// A hook command fed the JSON the app made for it, off the main actor, within `hookTimeout`.
    /// `.failure` is one line fit for the log and the card.
    static func hook(_ plugin: ToolPlugin, action: String, json: String) async -> Swift.Result<String, HookFailure> {
        let invocation: ToolPlugin.Invocation
        do {
            invocation = try plugin.invocation(action: action, args: [json])
        } catch {
            return .failure(HookFailure(message: error.localizedDescription))
        }
        let r = await Task.detached(priority: .utility) { run(invocation, timeout: hookTimeout) }.value
        guard r.code == 0 else {
            return .failure(HookFailure(message: "exit \(r.code)" + (r.err.isEmpty ? "" : " " + String(r.err.prefix(200)))))
        }
        return .success(r.out)
    }

    struct HookFailure: Error { var message: String }

    static func run(_ invocation: ToolPlugin.Invocation, timeout: TimeInterval? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: invocation.executable)
        p.arguments = invocation.arguments
        p.currentDirectoryURL = URL(fileURLWithPath: invocation.directory)
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        if invocation.stdin != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return Result(out: "", err: "無法執行 \(invocation.executable)：\(error.localizedDescription)", code: 127) }
        // Drain both pipes concurrently, and before feeding stdin: a child that answers while still
        // reading its input would otherwise block on a full pipe and so would we.
        final class Box: @unchecked Sendable {
            var out = Data(); var err = Data()
            let lock = NSLock(); private var killed = false
            func markKilled() { lock.lock(); killed = true; lock.unlock() }
            var wasKilled: Bool { lock.lock(); defer { lock.unlock() }; return killed }
        }
        let box = Box()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global(qos: .userInitiated).async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global(qos: .userInitiated).async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        var killer: DispatchWorkItem?
        if let timeout {
            // Only a process still running is reported as timed out; one that just finished is not.
            // Process puts the child in its own group, so the whole tree goes (a script's curl too).
            let item = DispatchWorkItem {
                guard p.isRunning else { return }
                box.markKilled()
                let pid = p.processIdentifier
                kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            killer = item
        }
        if let input = invocation.stdin {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
        group.wait()
        p.waitUntilExit()
        killer?.cancel()
        if box.wasKilled {
            return Result(out: "", err: "逾時（\(Int(timeout ?? 0)) 秒內沒有結束，已強制結束）", code: 124)
        }
        return Result(out: String(decoding: box.out.prefix(outputLimit), as: UTF8.self), err: String(decoding: box.err, as: UTF8.self),
                      code: p.terminationStatus)
    }
}
