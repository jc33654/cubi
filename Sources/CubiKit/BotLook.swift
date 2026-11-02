// Per-session overrides of a robot's shape and colour, chosen by the user from the island.
// Keyed by session id and remembered (the app persists them), so a session keeps its look when it
// comes back and across launches. Capped: when there are too many, the ones not currently live go
// first, oldest choice first.

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
    public static let limit = 200

    public private(set) var bySession: [String: BotLook] = [:]
    /// Session ids, most recently changed first; the order `prune` evicts in.
    public private(set) var recent: [String] = []

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

    public mutating func remove(_ sessionID: String) {
        bySession.removeValue(forKey: sessionID)
        recent.removeAll { $0 == sessionID }
    }

    /// Over the limit, drop looks of sessions that are not live, least recently changed first.
    /// Live sessions are never dropped.
    public mutating func prune(keeping live: Set<String>, limit: Int = BotLooks.limit) {
        var excess = bySession.count - limit
        guard excess > 0 else { return }
        for id in recent.reversed() where excess > 0 && !live.contains(id) {
            remove(id)
            excess -= 1
        }
    }

    private mutating func store(_ look: BotLook, for sessionID: String) {
        recent.removeAll { $0 == sessionID }
        if look.isDefault {
            bySession.removeValue(forKey: sessionID)
        } else {
            bySession[sessionID] = look
            recent.insert(sessionID, at: 0)
        }
    }
}
