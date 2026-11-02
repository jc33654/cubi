import Testing
@testable import CubiKit

private func start(_ id: String) -> DecodedHook {
    DecodedHook(session: SessionRef(id: id, cwd: "/Users/me/p", client: HookClient(termProgram: "ghostty")),
                event: .sessionStart(source: "startup"))
}

@Test func reorderChangesWhatIsShownAndKeepsUnmentionedBehind() {
    var store = SessionStore()
    for (i, id) in ["a", "b", "c", "d"].enumerated() { _ = store.apply(start(id), now: Double(i)) }
    store.reorder(["c", "a"])
    #expect(store.order == ["c", "a", "b", "d"])
    #expect(store.ordered.map(\.id) == ["c", "a", "b", "d"])
    #expect(store.preferredOrder == ["c", "a", "b", "d"])
}

@Test func seededOrderAppliesAsSessionsAppearAndNewOnesGoLast() {
    var store = SessionStore()
    store.seedOrder(["b", "a"])
    _ = store.apply(start("a"), now: 1)
    _ = store.apply(start("new"), now: 2)
    _ = store.apply(start("b"), now: 3)
    #expect(store.order == ["b", "a", "new"])
}

@Test func reorderRemembersSessionsThatAreNotLive() {
    var store = SessionStore()
    store.seedOrder(["gone", "a"])
    _ = store.apply(start("a"), now: 1)
    _ = store.apply(start("b"), now: 2)
    store.reorder(["b", "a"])
    #expect(store.order == ["b", "a"])
    #expect(store.preferredOrder == ["b", "a", "gone"])
    _ = store.apply(start("gone"), now: 3)
    #expect(store.order == ["b", "a", "gone"])
}

@Test func endedSessionReturnsToItsPlace() {
    var store = SessionStore()
    for (i, id) in ["a", "b", "c"].enumerated() { _ = store.apply(start(id), now: Double(i)) }
    store.reorder(["c", "b", "a"])
    store.forget("b")
    #expect(store.order == ["c", "a"])
    _ = store.apply(start("b"), now: 10)
    #expect(store.order == ["c", "b", "a"])
}

@Test func preferredOrderIsCapped() {
    var store = SessionStore()
    store.seedOrder((0..<300).map { "s\($0)" })
    #expect(store.preferredOrder.count == SessionStore.preferredOrderLimit)
}
