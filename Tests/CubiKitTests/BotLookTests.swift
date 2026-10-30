import Foundation
import Testing
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
}

@Test func colourIndexIsClampedToThePalette() {
    var looks = BotLooks()
    looks.setColorIndex(99, for: "a")
    #expect(looks.look(for: "a").colorIndex == SessionPalette.colors.count - 1)
    looks.setColorIndex(-5, for: "a")
    #expect(looks.look(for: "a").colorIndex == 0)
}

@Test func pruneKeepsOnlyLiveSessions() {
    var looks = BotLooks()
    looks.setShape(.triangle, for: "a")
    looks.setShape(.hexagon, for: "b")
    looks.prune(keeping: ["b", "c"])
    #expect(looks.bySession.keys.sorted() == ["b"])
    looks.remove("b")
    #expect(looks.bySession.isEmpty)
}

@Test func looksRoundTripThroughJSONWithStableNames() throws {
    var looks = BotLooks()
    looks.setShape(.circle, for: "s1")
    looks.setColorIndex(6, for: "s1")
    let data = try JSONEncoder().encode(looks)
    #expect(String(decoding: data, as: UTF8.self).contains("\"circle\""))
    #expect(try JSONDecoder().decode(BotLooks.self, from: data) == looks)
    #expect(BotShape.allCases.map(\.rawValue) == ["square", "circle", "triangle", "hexagon"])
}
