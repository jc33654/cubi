import Foundation

// `service` (experimental): one program Cubi starts and keeps running while the plugin is on. Its
// stdin and stdout are Cubi's channel to it, so it takes no arguments. Its argv is its own, not a
// name in `commands`: a Cubi that does not know `service` (0.2.0 and older) only warns about the key
// and has no way to start it, from a panel or `cubi --tool-run`.
extension ToolPlugin {
    public struct Service: Sendable, Equatable {
        /// argv, resolved like a command's: an absolute executable, then arguments.
        public var run: [String]
        public var restart: Restart
        /// What the program may ask Cubi for on stdout; anything else it prints is dropped.
        public var events: Set<ServiceEvent>
    }

    public enum Restart: String, Sendable, Equatable, CaseIterable {
        /// Start it again after it dies (exit other than 0, or a signal); exit 0 means it stopped on purpose.
        case onFailure = "on-failure"
        case never
    }

    public enum ServiceEvent: String, Sendable, Equatable, CaseIterable {
        case notice, present, state, log, reply
    }

    static func parseService(_ s: JSONValue, baseDirectory: String, home: String) throws -> Service {
        guard s.object != nil else { throw LoadError.badField("service", "要是物件") }
        guard let raw = s["run"] else { throw LoadError.missingField("service.run") }
        // Stricter than `commands.<action>.run`: an entry that is not a string is an error, not dropped.
        guard let items = raw.array, !items.isEmpty else { throw LoadError.badField("service.run", "要是非空的字串陣列") }
        let run = items.compactMap(\.string)
        guard run.count == items.count, !run[0].isEmpty else { throw LoadError.badField("service.run", "要是非空的字串陣列") }
        guard run[0].contains("/") || run[0] == "~" else {
            throw LoadError.badField("service.run", "執行檔要是路徑（絕對、~ 或相對插件目錄，不能只寫名字）")
        }
        if let word = run.first(where: { placeholder($0) != nil }) {
            throw LoadError.badField("service.run", "不能用 \(word)：背景服務沒有參數（stdin 是 Cubi 跟它溝通用的）")
        }
        let argv = [absolutePath(pluginPath(run[0], base: baseDirectory), base: baseDirectory, home: home)]
            + run.dropFirst().map { pluginPath($0, base: baseDirectory) }
        var restart = Restart.onFailure
        if let raw = s["restart"] {
            guard let r = raw.string.flatMap(Restart.init(rawValue:)) else {
                throw LoadError.badField("service.restart", "只能是 \(Restart.allCases.map(\.rawValue).joined(separator: "、"))")
            }
            restart = r
        }
        guard let list = s["events"]?.array else { throw LoadError.missingField("service.events") }
        var events: Set<ServiceEvent> = []
        for (i, e) in list.enumerated() {
            guard let event = e.string.flatMap(ServiceEvent.init(rawValue:)) else {
                throw LoadError.badField("service.events[\(i)]", "只能是 \(ServiceEvent.allCases.map(\.rawValue).joined(separator: "、"))")
            }
            guard events.insert(event).inserted else { throw LoadError.badField("service.events[\(i)]", "「\(event.rawValue)」重複了") }
        }
        guard !events.isEmpty else { throw LoadError.badField("service.events", "至少要列一種") }
        return Service(run: argv, restart: restart, events: events)
    }

    /// What Cubi runs for the service, in the plugin's directory like every command.
    public var serviceInvocation: Invocation? {
        guard let service else { return nil }
        return Invocation(executable: service.run[0], arguments: Array(service.run.dropFirst()), stdin: nil, reveal: false, directory: directory)
    }
}
