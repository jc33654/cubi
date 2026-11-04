import Foundation
import CubiKit

/// Runs a checked invocation without a shell, in the plugin's directory. stdin feeds long bodies
/// (too long for argv). A command that does not finish in `timeout` is killed.
enum ToolRunner {
    struct Result: Sendable {
        var out: String
        var err: String
        var code: Int32
    }

    static let defaultTimeout: TimeInterval = 20
    /// More than this on stdout is cut; no caller wants it (PluginIO stops at 64 KB).
    static let outputLimit = 4 << 20
    static let timeoutCode: Int32 = 124

    static func run(_ invocation: ToolPlugin.Invocation, timeout: TimeInterval = defaultTimeout) -> Result {
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
        final class Box: @unchecked Sendable { var out = Data(); var err = Data(); var timedOut = false }
        let box = Box()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global(qos: .userInitiated).async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global(qos: .userInitiated).async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let killer = DispatchWorkItem { box.timedOut = true; p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        if let input = invocation.stdin {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        if box.timedOut {
            return Result(out: "", err: "逾時（\(Int(timeout)) 秒內沒有結束）", code: timeoutCode)
        }
        let out = box.out.count > outputLimit ? box.out.prefix(outputLimit) : box.out[...]
        return Result(out: String(decoding: out, as: UTF8.self), err: String(decoding: box.err, as: UTF8.self),
                      code: p.terminationStatus)
    }
}
