import Testing
import Foundation
@testable import CubiKit

@Test func looksDefaultToNothingAndDropDefaults() {
    var looks = BotLooks()
    #expect(looks.look(for: "a") == BotLook())
    looks.setShape(.circle, for: "a")
    looks.setColorIndex(3, for: "a")
    #expect(looks.look(for: "a") == BotLook(shape: .circle, colorIndex: 3))
    looks.setShape(nil, for: "a")
    #expect(looks.look(for: "a") == BotLook(colorIndex: 3))
    looks.setColorIndex(nil, for: "a")
    #expect(looks.bySession.isEmpty)   // back to default: no entry kept
    #expect(looks.recent.isEmpty)
}

@Test func colourIndexIsClampedToThePalette() {
    var looks = BotLooks()
    looks.setColorIndex(99, for: "a")
    #expect(looks.look(for: "a").colorIndex == SessionPalette.colors.count - 1)
    looks.setColorIndex(-5, for: "a")
    #expect(looks.look(for: "a").colorIndex == 0)
}

@Test func pruneOnlyEvictsOverTheLimitAndNeverLiveSessions() {
    var looks = BotLooks()
    looks.setShape(.triangle, for: "old")
    looks.setShape(.hexagon, for: "mid")
    looks.setShape(.circle, for: "new")
    looks.prune(keeping: [], limit: 3)
    #expect(looks.bySession.count == 3)                    // under the limit: nothing goes
    looks.prune(keeping: ["old"], limit: 2)
    #expect(looks.bySession.keys.sorted() == ["new", "old"])  // "mid" was the oldest non-live choice
    looks.prune(keeping: ["old", "new"], limit: 1)
    #expect(looks.bySession.keys.sorted() == ["new", "old"])  // both live: kept even over the limit
}

@Test func looksRoundTripThroughJSON() throws {
    var looks = BotLooks()
    looks.setShape(.hexagon, for: "a")
    looks.setColorIndex(2, for: "b")
    let data = try JSONEncoder().encode(looks)
    let back = try JSONDecoder().decode(BotLooks.self, from: data)
    #expect(back == looks)
    #expect(back.recent == ["b", "a"])
}
