import Foundation

/// Terminal identity the relay attaches from its own environment (hooks carry none themselves).
public struct HookClient: Sendable, Equatable, Codable {
    public var termProgram: String?
    public var bundleID: String?
    public var termSessionID: String?
    public var tty: String?

    enum CodingKeys: String, CodingKey {
        case termProgram = "term_program"
        case bundleID = "bundle_id"
        case termSessionID = "term_session_id"
        case tty
    }

    public init(termProgram: String? = nil, bundleID: String? = nil, termSessionID: String? = nil, tty: String? = nil) {
        self.termProgram = termProgram
        self.bundleID = bundleID
        self.termSessionID = termSessionID
        self.tty = tty
    }
}

/// One line from cubi-hook: see docs/protocol.md.
public struct HookEnvelope: Sendable, Equatable, Codable {
    public var v: Int
    public var agent: String
    public var event: String?
    public var tool: String?
    public var pid: Int32
    public var ppid: Int32
    public var client: HookClient
    public var payload: JSONValue

    public init(v: Int = CubiInfo.protocolVersion, agent: String, event: String?, tool: String? = nil,
                pid: Int32 = 0, ppid: Int32 = 0, client: HookClient = HookClient(), payload: JSONValue) {
        self.v = v
        self.agent = agent
        self.event = event
        self.tool = tool
        self.pid = pid
        self.ppid = ppid
        self.client = client
        self.payload = payload
    }

    public static func parse(_ data: Data) throws -> HookEnvelope {
        try JSONDecoder().decode(HookEnvelope.self, from: data)
    }
}
