// What an Edit/Write did to a file, for the diff card. Prefers Claude Code's own structuredPatch
// in tool_response; falls back to diffing old_string/new_string, or to "everything added" for a
// brand-new file.

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case context, added, removed, hunk }
    public var kind: Kind
    public var text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

public struct EditSummary: Sendable, Equatable {
    public var path: String
    public var added: Int
    public var removed: Int
    public var lines: [DiffLine]
    public var truncated: Bool

    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var label: String { "\(fileName) +\(added) −\(removed)" }

    public init(path: String, added: Int, removed: Int, lines: [DiffLine], truncated: Bool) {
        self.path = path
        self.added = added
        self.removed = removed
        self.lines = lines
        self.truncated = truncated
    }
}

public enum EditSummaryBuilder {
    public static let editingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    public static let maxLines = 400

    public static func build(tool: String, input: JSONValue, response: JSONValue) -> EditSummary? {
        guard editingTools.contains(tool) else { return nil }
        let path = input["file_path"]?.string ?? response["filePath"]?.string ?? input["notebook_path"]?.string ?? "?"

        var lines: [DiffLine] = []
        if let hunks = response["structuredPatch"]?.array, !hunks.isEmpty {
            for hunk in hunks {
                let oldStart = Int(hunk["oldStart"]?.double ?? 0), newStart = Int(hunk["newStart"]?.double ?? 0)
                lines.append(DiffLine(kind: .hunk, text: "@@ -\(oldStart) +\(newStart) @@"))
                for raw in hunk["lines"]?.array ?? [] {
                    guard let l = raw.string else { continue }
                    let body = String(l.dropFirst())
                    switch l.first {
                    case "+": lines.append(DiffLine(kind: .added, text: body))
                    case "-": lines.append(DiffLine(kind: .removed, text: body))
                    default: lines.append(DiffLine(kind: .context, text: l.isEmpty ? "" : body))
                    }
                }
            }
        } else if let old = input["old_string"]?.string, let new = input["new_string"]?.string {
            lines = lineDiff(split(old), split(new))
        } else if let content = input["content"]?.string {
            if let original = response["originalFile"]?.string, !original.isEmpty {
                lines = lineDiff(split(original), split(content))
            } else {
                lines = split(content).map { DiffLine(kind: .added, text: $0) }
            }
        } else {
            return nil
        }

        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        let truncated = lines.count > maxLines
        if truncated { lines = Array(lines.prefix(maxLines)) }
        return EditSummary(path: path, added: added, removed: removed, lines: lines, truncated: truncated)
    }

    /// Lines without the phantom empty line a trailing newline would produce.
    static func split(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Plain LCS line diff; inputs are the small strings Edit works with, not whole files.
    public static func lineDiff(_ a: [String], _ b: [String]) -> [DiffLine] {
        let n = a.count, m = b.count
        guard n * m <= 4_000_000 else {
            return a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                out.append(DiffLine(kind: .context, text: a[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(DiffLine(kind: .removed, text: a[i])); i += 1
            } else {
                out.append(DiffLine(kind: .added, text: b[j])); j += 1
            }
        }
        while i < n { out.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
        while j < m { out.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        return out
    }
}
