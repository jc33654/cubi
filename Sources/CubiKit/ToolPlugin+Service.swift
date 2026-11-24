import Foundation

// `service` (experimental): one command Cubi starts and keeps running while the plugin is on. Its
// stdin and stdout are Cubi's channel to it, so it takes no arguments, and Cubi alone starts it.
extension ToolPlugin {
    public struct Service: Sendable, Equatable {
        /// The command Cubi starts.
        public var action: String
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

    static func parseService(_ s: JSONValue, commands: [String: Command]) throws -> Service {
        guard s.object != nil else { throw LoadError.badField("service", "要是物件") }
        guard let action = s["run"]?.string else { throw LoadError.missingField("service.run") }
        guard let c = commands[action] else { throw LoadError.badField("service.run", "沒有這個命令「\(action)」") }
        guard c.args.isEmpty, c.stdin == nil else {
            throw LoadError.badField("service.run", "「\(action)」不能有 args 或 stdin（stdin 是 Cubi 跟它溝通用的）")
        }
        guard !c.reveal, !c.sessionAllowed else { throw LoadError.badField("service.run", "「\(action)」不能 reveal 或 sessionAllowed") }
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
        return Service(action: action, restart: restart, events: events)
    }

    /// A panel or `cubi --tool-run` asking for the service command would start a second copy that
    /// nothing supervises (and a panel call has no time limit), so only Cubi starts it.
    public func isService(_ action: String) -> Bool { service?.action == action }

    /// What Cubi runs for the service: the command as declared, which has no arguments to fill in.
    public var serviceInvocation: Invocation? {
        guard let service, let c = commands[service.action] else { return nil }
        return Invocation(executable: c.run[0], arguments: Array(c.run.dropFirst()), stdin: nil, reveal: false, directory: directory)
    }
}
