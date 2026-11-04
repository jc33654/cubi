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

    func show(_ tool: ToolPlugin, session: PluginIO.SessionInput?) {
        bridge.tool = tool
        if let w = window, let web {
            // Already open: hand the page the new session without reloading (its state survives);
            // the page listens for `cubisession`. The user script is replaced too, for a later reload.
            if let session {
                web.configuration.userContentController.removeAllUserScripts()
                web.configuration.userContentController.addUserScript(Self.sessionScript(session))
                web.evaluateJavaScript(Self.sessionAssignment(session) + " window.dispatchEvent(new Event('cubisession'));")
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: tool.panel.bridge)
        if let session { cfg.userContentController.addUserScript(Self.sessionScript(session)) }
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        self.web = web
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: tool.panel.width, height: tool.panel.height),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = tool.displayName
        w.center()
        w.contentView = web
        w.delegate = self
        w.isReleasedWhenClosed = false
        window = w
        let html = (try? String(contentsOfFile: tool.panel.file, encoding: .utf8))
            ?? "<h2 style='font-family:-apple-system;padding:2rem'>找不到 \(tool.panel.file)</h2>"
        web.loadHTMLString(html, baseURL: nil)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The JSON is an object literal; a user script is not HTML, so nothing needs escaping.
    private static func sessionAssignment(_ session: PluginIO.SessionInput) -> String {
        "window.cubiSession = \(session.json());"
    }

    private static func sessionScript(_ session: PluginIO.SessionInput) -> WKUserScript {
        WKUserScript(source: sessionAssignment(session), injectionTime: .atDocumentStart, forMainFrameOnly: true)
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
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
}

@MainActor
private final class ToolBridge: NSObject, WKScriptMessageHandlerWithReply {
    var tool: ToolPlugin?
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool) { self.isEnabled = isEnabled }

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
