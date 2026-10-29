// Claude Code hook payloads → canonical events. Field names come from real captures of
// Claude Code 2.1.312 (Tests/CubiKitTests/Fixtures/claude-2.1.312). Unknown events decode to nil
// and are logged by the caller, never thrown: a newer Claude Code must not break the app.

public enum ClaudeCodeDecoder {
    public static func decode(_ e: HookEnvelope) -> DecodedHook? {
        let p = e.payload
        guard let sessionID = p["session_id"]?.string else { return nil }
        let session = SessionRef(id: sessionID, cwd: p["cwd"]?.string, client: e.client,
                                 transcriptPath: p["transcript_path"]?.string)
        let name = e.event ?? p["hook_event_name"]?.string ?? ""

        let event: CanonicalEvent?
        switch name {
        case "SessionStart":
            event = .sessionStart(source: p["source"]?.string)
        case "UserPromptSubmit":
            event = .prompt(p["prompt"]?.string ?? "")
        case "PreToolUse":
            let tool = p["tool_name"]?.string ?? e.tool ?? "?"
            let input = p["tool_input"] ?? .null
            // Only the matcher hook (`--tool AskUserQuestion`) holds its connection for an answer.
            // The plain PreToolUse hook also fires for the same call but is fire-and-forget.
            event = (tool == "AskUserQuestion" && e.tool == "AskUserQuestion")
                ? .question(input) : .toolStart(tool: tool, input: input)
        case "PostToolUse", "PostToolUseFailure":
            event = .toolEnd(tool: p["tool_name"]?.string ?? "?", ok: name == "PostToolUse",
                             input: p["tool_input"] ?? .null, response: p["tool_response"] ?? .null)
        case "PermissionRequest":
            event = .permissionRequest(tool: p["tool_name"]?.string ?? "?", input: p["tool_input"] ?? .null,
                                       suggestions: p["permission_suggestions"] ?? .null)
        case "Notification":
            event = .notification(type: p["notification_type"]?.string ?? "", message: p["message"]?.string ?? "")
        case "Stop", "StopFailure":
            event = .stop(lastMessage: p["last_assistant_message"]?.string)
        case "SessionEnd":
            event = .sessionEnd(reason: p["reason"]?.string)
        case "SubagentStart":
            event = .subagentStart(type: p["agent_type"]?.string)
        case "SubagentStop":
            event = .subagentStop(type: p["agent_type"]?.string)
        case "statusline":
            event = .statusline(statusline(p))
        default:
            event = nil
        }
        return event.map { DecodedHook(session: session, event: $0) }
    }

    static func statusline(_ p: JSONValue) -> StatuslineInfo {
        func window(_ v: JSONValue?) -> UsageWindow? {
            guard let used = v?["used_percentage"]?.double else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: v?["resets_at"]?.double)
        }
        return StatuslineInfo(
            sessionName: p["session_name"]?.string,
            model: p["model"]?["id"]?.string ?? p["model"]?["display_name"]?.string,
            contextPercent: p["context_window"]?["used_percentage"]?.double,
            fiveHour: window(p["rate_limits"]?["five_hour"]),
            sevenDay: window(p["rate_limits"]?["seven_day"]),
            costUSD: p["cost"]?["total_cost_usd"]?.double)
    }

    /// Short label for the ticker: what the tool is about to touch.
    public static func toolLabel(tool: String, input: JSONValue) -> String {
        func base(_ path: String?) -> String? { path.flatMap { $0.split(separator: "/").last.map(String.init) } }
        switch tool {
        case "Bash":
            let cmd = input["command"]?.string ?? ""
            let line = cmd.split(separator: "\n").first.map(String.init) ?? cmd
            return line.count > 48 ? String(line.prefix(47)) + "…" : line
        case "Edit", "Write", "Read", "NotebookEdit":
            return tool + " " + (base(input["file_path"]?.string) ?? "")
        case "Grep", "Glob":
            return tool + " " + (input["pattern"]?.string ?? "")
        case "Agent":
            return "Agent " + (input["description"]?.string ?? "")
        default:
            return tool
        }
    }
}
