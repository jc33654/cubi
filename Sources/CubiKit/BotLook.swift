// Per-session overrides of a robot's shape and colour, chosen by the user from the island.
// Keyed by session id on purpose: a session's look dies with the session.

public enum BotShape: String, CaseIterable, Sendable, Codable {
    case square, circle, triangle, hexagon

    public var displayName: String {
        switch self {
        case .square: return "方塊"
        case .circle: return "圓形"
        case .triangle: return "三角"
        case .hexagon: return "六角"
        }
    }
}

public struct BotLook: Sendable, Equatable, Codable {
    /// nil = the default square.
    public var shape: BotShape?
    /// Index into `SessionPalette.colors`; nil = the automatically assigned colour.
    public var colorIndex: Int?

    public init(shape: BotShape? = nil, colorIndex: Int? = nil) {
        self.shape = shape
        self.colorIndex = colorIndex
    }

    public var isDefault: Bool { shape == nil && colorIndex == nil }
}

public struct BotLooks: Sendable, Equatable, Codable {
    public private(set) var bySession: [String: BotLook] = [:]

    public init() {}

    public func look(for sessionID: String) -> BotLook { bySession[sessionID] ?? BotLook() }

    public mutating func setShape(_ shape: BotShape?, for sessionID: String) {
        var l = look(for: sessionID)
        l.shape = shape
        store(l, for: sessionID)
    }

    public mutating func setColorIndex(_ index: Int?, for sessionID: String) {
        var l = look(for: sessionID)
        l.colorIndex = index.map { max(0, min(SessionPalette.colors.count - 1, $0)) }
        store(l, for: sessionID)
    }

    public mutating func remove(_ sessionID: String) { bySession.removeValue(forKey: sessionID) }

    /// Forget every session that is no longer live.
    public mutating func prune(keeping live: Set<String>) {
        bySession = bySession.filter { live.contains($0.key) }
    }

    private mutating func store(_ look: BotLook, for sessionID: String) {
        if look.isDefault { bySession.removeValue(forKey: sessionID) } else { bySession[sessionID] = look }
    }
}
