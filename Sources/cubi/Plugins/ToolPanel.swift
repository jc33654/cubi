import AppKit
import WebKit
import CubiKit

/// Windows for tool plugins, one per plugin, opened from the menu or the settings page.
@MainActor
final class ToolPanels {
    private let registry: PluginRegistry
    private var panels: [String: ToolPanel] = [:]

    init(registry: PluginRegistry) { self.registry = registry }

    /// `session`: opened from a session's detail card; the page gets it as `window.cubiSession`.
    func show(_ id: String, session: PluginIO.SessionInput? = nil) {
        guard let tool = registry.tools.first(where: { $0.id == id }), registry.isEnabled(id) else {
            CubiLog.write("tool \(id): not loaded or disabled")
            return
        }
        let panel = panels[id] ?? ToolPanel(isEnabled: { [registry] in registry.isEnabled(id) })
        panels[id] = panel
        panel.show(tool, session: session)
    }
}

/// A tool plugin's panel: a WKWebView whose JavaScript can only run the commands the manifest
/// lists, by posting `{action, args}` (or `{action, name, value}`) to
/// `window.webkit.messageHandlers.<bridge>`. The HTML is re-read every time the window opens, so
/// a panel can change without a rebuild. `baseURL: nil` means no file:// base and a null origin;
/// it does not stop the page from loading external resources (the HTML is the user's own, trusted
/// like the manifest). Links to http(s) open in the browser, never inside the panel.
@MainActor
final class ToolPanel: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private let bridge: ToolBridge

    /// `isEnabled` is asked on every message, so switching the plugin off in the settings stops
    /// an open panel too.
    init(isEnabled: @escaping () -> Bool) {
        bridge = ToolBridge(isEnabled: isEnabled)
    }

    func show(_ tool: ToolPlugin, session: PluginIO.SessionInput?, offscreen: Bool = false, appearance: NSAppearance? = nil) {
        bridge.tool = tool
        if let w = window, let web {
            // Already open: hand the page the new session without reloading (its state survives);
            // the page listens for `cubisession`. The user script is replaced too, for a later reload.
            if let session {
                // Replace every user script with the full set again: the style kit must survive.
                Self.install(tool, session: session, into: web.configuration.userContentController)
                web.evaluateJavaScript(Self.sessionAssignment(session) + " window.dispatchEvent(new Event('cubisession'));")
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: tool.panel.bridge)
        Self.install(tool, session: session, into: cfg.userContentController)
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        self.web = web
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: tool.panel.width, height: tool.panel.height),
                         // Off screen (rendering): borderless, so the frame is not clamped to the display's height.
                         styleMask: offscreen ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = tool.displayName
        w.center()
        if let appearance { w.appearance = appearance }
        if offscreen { w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)) }
        w.contentView = web
        w.delegate = self
        w.isReleasedWhenClosed = false
        window = w
        let html = (try? String(contentsOfFile: tool.panel.file, encoding: .utf8))
            ?? "<h2 style='font-family:-apple-system;padding:2rem'>找不到 \(tool.panel.file)</h2>"
        web.loadHTMLString(html, baseURL: nil)
        if offscreen { w.orderBack(nil); return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// For `--render-panel --eval`: whatever the script returns is printed.
    func evaluate(_ script: String) {
        web?.evaluateJavaScript(script) { value, error in
            print("eval → \(value.map { "\($0)" } ?? "nil")\(error.map { " error: \($0.localizedDescription)" } ?? "")")
        }
    }

    func snapshot(_ done: @escaping @MainActor (NSImage?) -> Void) {
        guard let web else { return done(nil) }
        web.takeSnapshot(with: nil) { image, _ in MainActor.assumeIsolated { done(image) } }
    }

    /// The JSON is an object literal; a user script is not HTML, so nothing needs escaping.
    private static func sessionAssignment(_ session: PluginIO.SessionInput) -> String {
        "window.cubiSession = \(session.json());"
    }

    /// The page's user scripts, always as one set: the style kit when the manifest asks for it,
    /// then the session. Rebuilt whole, so replacing the session never drops the styles.
    private static func install(_ tool: ToolPlugin, session: PluginIO.SessionInput?, into ucc: WKUserContentController) {
        ucc.removeAllUserScripts()
        if tool.panel.style == .cubi {
            ucc.addUserScript(WKUserScript(source: PanelStyleKit.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let session {
            ucc.addUserScript(WKUserScript(source: sessionAssignment(session), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        web = nil
    }

    /// Any navigation away from the loaded HTML (a link, `location.href`, a form, a meta refresh)
    /// is refused: the bridge belongs to this web view, and a remote page must never get to use
    /// it. http(s) targets open in the browser instead.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme?.lowercased() != "about" else {
            decisionHandler(.allow)
            return
        }
        // A sub-frame (an iframe) is refused quietly; only the page's own navigation opens the browser.
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), action.targetFrame?.isMainFrame ?? true { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
}

@MainActor
private final class ToolBridge: NSObject, WKScriptMessageHandlerWithReply {
    var tool: ToolPlugin?
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool) { self.isEnabled = isEnabled }

    private static let question = LinePrompt()

    /// What the agent will be told is shown in full up to 400 characters, so agreeing means seeing it.
    static func confirmSession(tool: String, directory: String, prompt: String?) async -> Bool {
        let shown = prompt.map { $0.count > 400 ? $0.prefix(400) + "…（共 \($0.count) 字）" : $0 } ?? "（沒有）"
        return await question.confirm("\(tool) 想開一個 Claude Code session", "目錄：\(directory)\n要交給 Claude 的話：\(shown)", button: "開啟")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let tool, let body = message.body as? [String: Any], let action = body["action"] as? String else {
            replyHandler(nil, "請求格式錯誤")
            return
        }
        guard isEnabled() else {
            replyHandler(nil, "這個插件已在設定頁關閉")
            return
        }
        // Built in: start a Claude Code session in a directory with a first prompt, the way the
        // 開新 session dialog does. `{action:"session.new", args:["{\"directory\":…,\"prompt\":…}"]}`.
        // The manifest must ask for it (`"builtins": ["session.new"]`), and the user confirms
        // every time: a panel page can load outside scripts, and this hands a prompt to an agent.
        // Answers `{ok:false, err}` on failure like a command, never a reject.
        if action == "session.new" {
            guard tool.builtins.contains("session.new") else {
                replyHandler(["ok": false, "err": "manifest 沒有宣告 builtins: [\"session.new\"]"], nil)
                return
            }
            guard let raw = (body["args"] as? [String])?.first, let data = raw.data(using: .utf8),
                  let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dir = spec["directory"] as? String, !dir.isEmpty else {
                replyHandler(["ok": false, "err": "session.new 要 args[0] 是 {\"directory\", \"prompt\"} 的 JSON"], nil)
                return
            }
            let directory = ((dir as NSString).expandingTildeInPath as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
                replyHandler(["ok": false, "err": "找不到目錄 \(directory)"], nil)
                return
            }
            let prompt = (spec["prompt"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(ToolPlugin.textLimit)) }
            Task { @MainActor in
                // One question at a time, across plugins: a second request must not replace the
                // panel under the user's cursor and get the click meant for the first.
                guard !Self.question.isAsking else {
                    replyHandler(["ok": false, "err": "已有一個開 session 的確認在等你回答"], nil)
                    return
                }
                guard await Self.confirmSession(tool: tool.displayName, directory: directory, prompt: prompt) else {
                    replyHandler(["ok": false, "err": "已取消", "cancelled": true], nil)
                    return
                }
                // The app kept running while the question was open: the plugin may have been turned off.
                guard self.isEnabled() else {
                    replyHandler(["ok": false, "err": "這個插件已在設定頁關閉"], nil)
                    return
                }
                CubiLog.write("tool \(tool.id) session.new in \(directory)")
                let error = await SessionLauncher.launch(LaunchRequest(directory: directory, prompt: prompt, resume: .none, terminal: .automatic))
                replyHandler(error.map { ["ok": false, "err": $0] } ?? ["ok": true], nil)
            }
            return
        }
        // Built in: native file pickers, no command involved.
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
        var args: [String] = []
        if let list = body["args"] as? [String] {
            args = list
        } else if body["args"] != nil {
            replyHandler(nil, "args 要是字串陣列")
            return
        } else {
            if let name = body["name"] as? String { args.append(name) }
            if let value = body["value"] as? String { args.append(value) }
        }
        let invocation: ToolPlugin.Invocation
        do {
            invocation = try tool.invocation(action: action, args: args)
        } catch {
            CubiLog.write("tool \(tool.id) \(action): rejected: \(error.localizedDescription)")
            replyHandler(nil, error.localizedDescription)
            return
        }
        CubiLog.write("tool \(tool.id) \(action)")
        let id = tool.id
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ToolRunner.run(invocation)
            DispatchQueue.main.async {
                if r.code != 0 { CubiLog.write("tool \(id) \(action): exit \(r.code) \(r.err.prefix(200))") }
                if invocation.reveal {
                    let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                    replyHandler(["ok": !path.isEmpty, "out": path, "err": r.err], nil)
                } else {
                    replyHandler(["ok": r.code == 0, "out": r.out, "err": r.err], nil)
                }
            }
        }
    }
}

/// `--render-panel`: the same web view set-up as a real panel (style kit, bridge, navigation
/// rules), in a window parked off screen, photographed once the page has had time to call its
/// commands and draw.
@MainActor
enum PanelRenderer {
    private static var keep: [AnyObject] = []

    static func render(_ tool: ToolPlugin, dark: Bool, to url: URL, script: String? = nil, after delay: TimeInterval = 4,
                       done: @escaping (Bool) -> Void) {
        let panel = ToolPanel(isEnabled: { true })
        keep.append(panel)
        panel.show(tool, session: nil, offscreen: true, appearance: NSAppearance(named: dark ? .darkAqua : .aqua))
        if let script {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { panel.evaluate(script) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + (script == nil ? 0 : 2)) {
            panel.snapshot { image in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else {
                    FileHandle.standardError.write(Data("cubi: snapshot failed\n".utf8))
                    return done(false)
                }
                print("wrote \(url.path) (\(Int(image.size.width))×\(Int(image.size.height)))")
                done(true)
            }
        }
    }
}
