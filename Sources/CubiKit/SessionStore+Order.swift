// The user's arrangement of the robots. `order` is what is shown; `preferredOrder` remembers the
// arrangement across sessions coming and going (and across launches, via the app's defaults).

extension SessionStore {
    /// Same cap as the looks: how many sessions the app remembers things about.
    public static let preferredOrderLimit = BotLooks.limit

    /// Restore an arrangement saved by a previous run. Sessions already live are rearranged to it.
    public mutating func seedOrder(_ ids: [String]) {
        preferredOrder = Array(ids.prefix(Self.preferredOrderLimit))
        order = Self.sorted(order, by: preferredOrder)
    }

    /// The user dropped a robot: `ids` is the new order of the sessions they see. Sessions not
    /// mentioned keep their relative order after those; the arrangement is remembered, with the
    /// sessions that are not live right now kept behind the live ones.
    public mutating func reorder(_ ids: [String]) {
        var seen = Set<String>()
        let live = ids.filter { sessions[$0] != nil && seen.insert($0).inserted } + order.filter { !seen.contains($0) }
        order = live
        let remembered = preferredOrder.filter { !seen.contains($0) && sessions[$0] == nil }
        preferredOrder = Array((live + remembered).prefix(Self.preferredOrderLimit))
    }

    /// A session just appeared at the end of `order`: if the user had placed it, this moves it back.
    mutating func placeByPreference(_ id: String) {
        order = Self.sorted(order, by: preferredOrder)
    }

    /// Stable: arranged ids in their arranged order, then everything else in its current order.
    public static func sorted(_ ids: [String], by preferred: [String]) -> [String] {
        let rank = Dictionary(preferred.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated().sorted { a, b in
            let ra = rank[a.element] ?? Int.max, rb = rank[b.element] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
