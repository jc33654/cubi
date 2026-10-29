import AppKit
import WebKit

/// The Claude Toolkit management panel (~/.claude-toolkit/panel/index.html), ported from
/// ClaudeToolkit.app's Panel.swift: a WKWebView whose JS can only call whitelisted cctl actions.
/// The HTML is re-read every time the window opens, so the panel's UI can change without a rebuild.
@MainActor
final class ToolkitPanel: NSObject, NSWindowDelegate {
    nonisolated static let root = NSHomeDirectory() + "/.claude-toolkit"
    nonisolated static let cctlPath = root + "/bin/cctl"
    nonisolated static let htmlPath = root + "/panel/index.html"

    private var window: NSWindow?
    private let bridge = ToolkitBridge()

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "cctl")
        let web = WKWebView(frame: .zero, configuration: cfg)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Claude Toolkit"
        w.center()
        w.contentView = web
        w.delegate = self
        w.isReleasedWhenClosed = false
        window = w
        let html = (try? String(contentsOfFile: Self.htmlPath, encoding: .utf8))
            ?? "<h2 style='font-family:-apple-system;padding:2rem'>找不到 \(Self.htmlPath)</h2>"
        // baseURL nil: the page cannot load anything external.
        web.loadHTMLString(html, baseURL: nil)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - cctl bridge (whitelist, exec without a shell)

private let editableKinds = ["skills", "commands", "agents", "styles", "rules"]

private func isSafeName(_ s: String) -> Bool {
    if s.isEmpty || s.count > 64 { return false }
    let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return s.unicodeScalars.allSatisfy { ok.contains($0) }
}

private func isSafeValue(_ s: String) -> Bool {
    if s.isEmpty || s.count > 512 || s.hasPrefix("-") { return false }
    return s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
}

private func resolveArgs(action: String, args: [String]) -> [String]? {
    switch action {
    case "kb.add", "kb.import":
        guard args.count == 2, isSafeName(args[0]), isSafeValue(args[1]) else { return nil }
        return ["kb", action == "kb.add" ? "add" : "import", args[0], args[1]]
    case "skill.import", "cmd.import", "role.import", "style.import":
        guard args.count == 1, isSafeValue(args[0]) else { return nil }
        return [String(action.split(separator: ".")[0]), "import", args[0]]
    case "asset.read":
        guard args.count == 2, editableKinds.contains(args[0]), isSafeName(args[1]) else { return nil }
        return ["edit", "read", args[0], args[1]]
    default:
        return nil
    }
}

private func resolve(action: String, name: String?, value: String?) -> [String]? {
    switch action {
    case "status": return ["status", "--json"]
    case "doctor": return ["doctor"]
    case "doctor.fix": return ["doctor", "--fix"]
    case "profile.list": return ["profile", "list"]
    case "notify.on": return ["notify", "on"]
    case "notify.off": return ["notify", "off"]
    default: break
    }
    if action == "config.set" {
        guard let n = name, isSafeName(n), let v = value, isSafeValue(v) else { return nil }
        return ["config", "set", n, v]
    }
    guard let n = name, isSafeName(n) else { return nil }
    let table: [String: [String]] = [
        "skill.on": ["skill", "on"], "skill.off": ["skill", "off"],
        "cmd.on": ["cmd", "on"], "cmd.off": ["cmd", "off"],
        "kb.on": ["kb", "on"], "kb.off": ["kb", "off"], "kb.update": ["kb", "update"],
        "notify.target": ["notify", "target"],
        "role.on": ["role", "on"], "role.off": ["role", "off"], "role.use": ["role", "use"],
        "style.on": ["style", "on"], "style.off": ["style", "off"], "style.use": ["style", "use"],
        "profile.apply": ["profile", "apply"],
    ]
    guard let base = table[action] else { return nil }
    return base + [n]
}

/// stdin feeds skill/command bodies: too long for argv.
private func runCctl(_ args: [String], stdin input: String? = nil) -> (out: String, err: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ToolkitPanel.cctlPath)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    if input != nil { p.standardInput = inPipe }
    do { try p.run() } catch { return ("", "無法執行 cctl：\(error.localizedDescription)", 127) }
    if let input {
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        inPipe.fileHandleForWriting.closeFile()
    }
    // Drain both pipes concurrently or a chatty child deadlocks on a full pipe.
    final class Box: @unchecked Sendable { var out = Data(); var err = Data() }
    let box = Box()
    let group = DispatchGroup()
    group.enter(); DispatchQueue.global(qos: .userInitiated).async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter(); DispatchQueue.global(qos: .userInitiated).async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.wait()
    p.waitUntilExit()
    return (String(data: box.out, encoding: .utf8) ?? "", String(data: box.err, encoding: .utf8) ?? "", p.terminationStatus)
}

@MainActor
private final class ToolkitBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else {
            replyHandler(nil, "請求格式錯誤")
            return
        }
        if action == "pick.file" || action == "pick.dir" {
            let panel = NSOpenPanel()
            panel.canChooseFiles = action == "pick.file"
            panel.canChooseDirectories = action == "pick.dir"
            panel.allowsMultipleSelection = false
            panel.prompt = "選擇"
            if panel.runModal() == .OK, let url = panel.url {
                replyHandler(["ok": true, "path": url.path], nil)
            } else {
                replyHandler(["ok": false, "path": "", "cancelled": true], nil)
            }
            return
        }
        if action == "asset.write" {
            guard let a = body["args"] as? [String], a.count == 3, editableKinds.contains(a[0]), isSafeName(a[1]),
                  a[2].utf8.count <= 262_144 else {
                replyHandler(nil, "不允許的寫入請求")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let r = runCctl(["edit", "write", a[0], a[1]], stdin: a[2])
                DispatchQueue.main.async { replyHandler(["ok": r.code == 0, "out": r.out, "err": r.err], nil) }
            }
            return
        }
        if action == "asset.reveal" {
            guard let a = body["args"] as? [String], a.count == 2, editableKinds.contains(a[0]), isSafeName(a[1]) else {
                replyHandler(nil, "不允許的請求")
                return
            }
            let r = runCctl(["edit", "path", a[0], a[1]])
            let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            replyHandler(["ok": !path.isEmpty, "out": path, "err": r.err], nil)
            return
        }
        let resolved: [String]?
        if let list = body["args"] as? [String] {
            resolved = resolveArgs(action: action, args: list)
        } else {
            resolved = resolve(action: action, name: body["name"] as? String, value: body["value"] as? String)
        }
        guard let args = resolved else {
            replyHandler(nil, "不允許的請求：\(action)")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runCctl(args)
            DispatchQueue.main.async { replyHandler(["ok": r.code == 0, "out": r.out, "err": r.err], nil) }
        }
    }
}
