import Foundation

// Turning a panel request into argv: the caller's arguments checked against the declared types.
extension ToolPlugin {
    public enum InvokeError: Error, Equatable, LocalizedError {
        case unknownAction(String)
        case argumentCount(expected: Int, got: Int)
        case badArgument(index: Int, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unknownAction(let a): return "不允許的請求：\(a)"
            case .argumentCount(let e, let g): return "參數數量不符（要 \(e) 個，收到 \(g) 個）"
            case .badArgument(let i, let r): return "第 \(i) 個參數不合法：\(r)"
            }
        }
    }

    // MARK: - Invoking

    public func invocation(action: String, args: [String]) throws -> Invocation {
        guard let command = commands[action] else { throw InvokeError.unknownAction(action) }
        guard args.count == command.args.count else {
            throw InvokeError.argumentCount(expected: command.args.count, got: args.count)
        }
        for (i, (value, type)) in zip(args, command.args).enumerated() {
            if let reason = Self.problem(with: value, as: type) { throw InvokeError.badArgument(index: i + 1, reason: reason) }
        }
        let arguments = command.run.dropFirst().map { word -> String in
            guard let n = Self.placeholder(word) else { return word }
            return args[n - 1]
        }
        return Invocation(executable: command.run[0], arguments: Array(arguments),
                          stdin: command.stdin.map { args[$0 - 1] }, reveal: command.reveal, directory: directory)
    }

    static func problem(with value: String, as type: ArgType) -> String? {
        switch type {
        case .name:
            guard !value.isEmpty, value.count <= 64 else { return "名稱要 1–64 字" }
            if value == "." || value == ".." { return "名稱不能是 . 或 .." }
            let ok = value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-") }
            return ok ? nil : "名稱只能有英數、.、_、-"
        case .value:
            guard !value.isEmpty, value.count <= 512 else { return "值要 1–512 字" }
            if value.hasPrefix("-") { return "值不能以 - 開頭" }
            let ok = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
            return ok ? nil : "值不能有控制字元"
        case .text:
            return value.utf8.count <= textLimit ? nil : "內容超過 \(textLimit / 1024) KB"
        case .choice(let choices):
            return choices.contains(value) ? nil : "要是 \(choices.joined(separator: "、")) 之一"
        }
    }

    /// `$3` → 3; anything else nil.
    static func placeholder(_ word: String) -> Int? {
        guard word.hasPrefix("$"), let n = Int(word.dropFirst()) else { return nil }
        return n
    }
}
