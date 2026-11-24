import AppKit
import WebKit
import CubiKit

@MainActor
final class ToolBridge: NSObject, WKScriptMessageHandlerWithReply {
    var tool: ToolPlugin?
    private let isEnabled: () -> Bool
    private let services: () -> PluginServices?

    init(isEnabled: @escaping () -> Bool, services: @escaping () -> PluginServices? = { nil }) {
        self.isEnabled = isEnabled
        self.services = services
    }

    private static let question = LinePrompt()

    /// What the agent will be told is shown in full up to 400 characters, so agreeing means seeing it.
    static func confirmSession(tool: String, spec: SessionNewSpec) async -> Bool {
        await question.confirm("\(tool) 想開一個\(spec.restricted ? "受限模式的" : "") Claude Code session",
                               spec.confirmation(), button: "開啟")
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
            let spec: SessionNewSpec
            do {
                spec = try SessionNewSpec.parse((body["args"] as? [String])?.first, promptLimit: ToolPlugin.textLimit, actions: tool.sessionActions) { path in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                }
            } catch {
                replyHandler(["ok": false, "err": (error as? SessionNewSpec.ParseError)?.message ?? "\(error)"], nil)
                return
            }
            let directory = spec.directory, prompt = spec.prompt
            Task { @MainActor in
                // One question at a time, across plugins: a second request must not replace the
                // panel under the user's cursor and get the click meant for the first.
                guard !Self.question.isAsking else {
                    replyHandler(["ok": false, "err": "已有一個開 session 的確認在等你回答"], nil)
                    return
                }
                guard await Self.confirmSession(tool: tool.displayName, spec: spec) else {
                    replyHandler(["ok": false, "err": "已取消", "cancelled": true], nil)
                    return
                }
                // The app kept running while the question was open: the plugin may have been turned off.
                guard self.isEnabled() else {
                    replyHandler(["ok": false, "err": "這個插件已在設定頁關閉"], nil)
                    return
                }
                var restricted: SessionLaunch.Restricted?
                if spec.restricted {
                    do {
                        // One rule per action the plugin named, each for `<this cubi> --tool-run <this plugin> <action>` only.
                        let rules = spec.allowActions.map { SessionLaunch.allowRule(cubi: ToolRunner.cubiBinary, tool: tool.id, action: $0) }
                        guard !rules.contains(nil) else {
                            // Say which it is: the install path, or (a manifest older than the action-name rule) the action.
                            let err = SessionLaunch.isPlainPath(ToolRunner.cubiBinary)
                                ? "動作名稱「\(zip(spec.allowActions, rules).filter { $0.1 == nil }.map(\.0).joined(separator: "、"))」有英數、.、_、- 以外的字元，受限模式沒辦法只放行它，所以不開 session。"
                                : "Cubi 的安裝路徑（\(ToolRunner.cubiBinary)）有空白或特殊字元，受限模式沒辦法只放行指定的動作，所以不開 session。把 Cubi.app 放在路徑只有英數、/、.、_、- 的位置。"
                            replyHandler(["ok": false, "err": err], nil)
                            return
                        }
                        restricted = .init(settingsFile: try HookSetup.writeRestrictedSettings(directory: directory).path, readDirs: spec.readDirs,
                                           allowedTools: rules.compactMap { $0 })
                    } catch {
                        // Never fall back to an ordinary session: the plugin asked for the restricted one.
                        replyHandler(["ok": false, "err": "寫不出受限模式的設定檔：\(error.localizedDescription)"], nil)
                        return
                    }
                }
                CubiLog.write("tool \(tool.id) session.new in \(directory)\(spec.restricted ? " (restricted)" : "")")
                let error = await SessionLauncher.launch(LaunchRequest(directory: directory, prompt: prompt, resume: .none, terminal: .automatic, restricted: restricted))
                replyHandler(error.map { ["ok": false, "err": $0] } ?? ["ok": true], nil)
            }
            return
        }
        // Built in: the plugin's own service. `service.call` sends it `{type:"call"}` and answers
        // with its `reply` as `{ok, out, err}`; `service.state` answers `{ok, state}` with the last
        // `state` it sent (null before the first). Only for a manifest with `service`.
        if action == "service.call" || action == "service.state" {
            let fail = { (err: String) in replyHandler(["ok": false, "out": NSNull(), "err": err], nil) }
            guard tool.service != nil else { return fail("manifest 沒有 service") }
            guard let services = services() else { return fail("背景服務沒有在跑") }
            if action == "service.state" {
                replyHandler(["ok": true, "state": Self.foundation(services.state(of: tool.id) ?? .null)], nil)
                return
            }
            guard let list = body["args"] as? [String] else { return fail("args 要是字串陣列：動作，以及可選的 JSON 物件字串") }
            let request: (action: String, args: JSONValue?)
            switch ServiceProtocol.panelCall(list) {
            case .success(let parsed): request = parsed
            case .failure(let problem): return fail(problem.localizedDescription)
            }
            let id = tool.id
            Task { @MainActor in
                let result = await services.call(id, action: request.action, args: request.args)
                if let err = result.err { CubiLog.write("tool \(id) service.call \(request.action): \(err)") }
                replyHandler(["ok": result.ok, "out": Self.foundation(result.out ?? .null), "err": result.err ?? ""], nil)
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

    /// What WebKit hands the page as plain JavaScript values.
    static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(foundation)
        case .object(let o): o.mapValues(foundation)
        }
    }
}
