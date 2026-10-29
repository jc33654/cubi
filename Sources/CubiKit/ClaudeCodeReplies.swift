import Foundation

/// The JSON lines cubi-hook prints back to Claude Code for blocking events. Shapes follow the
/// hooks reference (PermissionRequest `decision`, PreToolUse `updatedInput` for AskUserQuestion).
public enum ClaudeCodeReplies {
    public enum PermissionDecision: Sendable, Equatable {
        case allow
        /// Allow and let Claude Code persist the rule it suggested (`permission_suggestions`).
        case always(suggestions: JSONValue)
        case deny(message: String)
    }

    public static func permission(_ d: PermissionDecision) -> String {
        var decision: [String: JSONValue]
        switch d {
        case .allow:
            decision = ["behavior": .string("allow")]
        case .always(let suggestions):
            decision = ["behavior": .string("allow")]
            if case .array(let a) = suggestions, !a.isEmpty { decision["updatedPermissions"] = suggestions }
        case .deny(let message):
            decision = ["behavior": .string("deny"), "message": .string(message)]
        }
        return encode(.object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": .object(decision),
        ])]))
    }

    /// `questions` is the tool_input's original array; `answers` maps question text to the chosen
    /// label(s). Multi-select answers are joined with ", " as the tool expects.
    public static func question(questions: JSONValue, answers: [String: String]) -> String {
        encode(.object(["hookSpecificOutput": .object([
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string("allow"),
            "updatedInput": .object([
                "questions": questions,
                "answers": .object(answers.mapValues { .string($0) }),
            ]),
        ])]))
    }

    /// The same answers, when the question arrived through the PermissionRequest flow instead.
    public static func questionViaPermission(questions: JSONValue, answers: [String: String]) -> String {
        encode(.object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": .object([
                "behavior": .string("allow"),
                "updatedInput": .object([
                    "questions": questions,
                    "answers": .object(answers.mapValues { .string($0) }),
                ]),
            ]),
        ])]))
    }

    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// One AskUserQuestion question as the tool describes it.
public struct AskQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String
        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }
    public var question: String
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String, options: [Option], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// Parses `tool_input.questions`; nil when the shape is not what AskUserQuestion sends.
    public static func parse(_ input: JSONValue) -> [AskQuestion]? {
        guard let list = input["questions"]?.array, !list.isEmpty else { return nil }
        var out: [AskQuestion] = []
        for q in list {
            guard let text = q["question"]?.string, let opts = q["options"]?.array, !opts.isEmpty else { return nil }
            let options = opts.compactMap { o -> Option? in
                guard let label = o["label"]?.string else { return nil }
                return Option(label: label, description: o["description"]?.string ?? "")
            }
            guard !options.isEmpty else { return nil }
            out.append(AskQuestion(question: text, header: q["header"]?.string ?? "", options: options,
                                   multiSelect: q["multiSelect"]?.bool ?? false))
        }
        return out
    }
}

/// What an approval card shows for a tool call: a one-line title and the thing being touched.
public enum ApprovalSummary {
    public static func describe(tool: String, input: JSONValue) -> (title: String, detail: String) {
        switch tool {
        case "Bash":
            return ("執行指令", input["command"]?.string ?? "")
        case "Edit", "Write", "NotebookEdit":
            return ("修改檔案", input["file_path"]?.string ?? "")
        case "Read":
            return ("讀取檔案", input["file_path"]?.string ?? "")
        case "WebFetch":
            return ("抓取網頁", input["url"]?.string ?? "")
        case "WebSearch":
            return ("搜尋網路", input["query"]?.string ?? "")
        default:
            let text = ClaudeCodeReplies.encode(input)
            return ("使用工具 \(tool)", text.count > 160 ? String(text.prefix(159)) + "…" : text)
        }
    }
}
