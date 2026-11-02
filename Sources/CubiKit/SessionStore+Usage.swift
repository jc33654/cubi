// Account-wide usage, merged across sessions (SessionStore+Order.swift holds the arrangement).

extension SessionStore {
    /// Restore a reading saved by a previous run.
    public mutating func seedUsage(_ info: StatuslineInfo) { usage = info }

    public static func windowsChanged(from old: StatuslineInfo?, to new: StatuslineInfo) -> Bool {
        new.fiveHour != old?.fiveHour || new.sevenDay != old?.sevenDay
    }

    /// A window from the most recently active session replaces what we have; from any other
    /// session it only fills a blank. Returns the merged reading when a window or the cost changed
    /// (`windowsChanged(from:to:)` tells the two apart).
    mutating func mergeUsage(_ info: StatuslineInfo, from id: String) -> StatuslineInfo? {
        let newest = sessions.values.map(\.lastEventAt).max()
        let fresh = sessions[id].map { $0.lastEventAt >= (newest ?? 0) } ?? false
        func pick(_ new: UsageWindow?, over old: UsageWindow?) -> UsageWindow? {
            guard let new else { return old }
            return fresh || old == nil ? new : old
        }
        var merged = info
        merged.fiveHour = pick(info.fiveHour, over: usage?.fiveHour)
        merged.sevenDay = pick(info.sevenDay, over: usage?.sevenDay)
        guard Self.windowsChanged(from: usage, to: merged) || merged.costUSD != usage?.costUSD else { return nil }
        usage = merged
        return merged
    }
}
