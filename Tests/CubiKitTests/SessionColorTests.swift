import Testing
@testable import CubiKit

@Test func sameSessionSameColour() {
    let a = SessionPalette.index(for: "7696156f-6ac7-4f32-b8b0-fcdfcc2af898")
    let b = SessionPalette.index(for: "7696156f-6ac7-4f32-b8b0-fcdfcc2af898")
    #expect(a == b)
}

@Test func fnv1aMatchesReferenceVector() {
    // Standard FNV-1a 64-bit test vector.
    #expect(SessionPalette.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
}

@Test func takenIndexIsSkipped() {
    let id = "bedb82d9-d033-4e3a-aa7d-13a07a1a1bd0"
    let free = SessionPalette.index(for: id)
    let bumped = SessionPalette.index(for: id, taken: [free])
    #expect(bumped != free)
    #expect(bumped == (free + 1) % SessionPalette.colors.count)
}

@Test func fullPaletteStillReturnsAnIndex() {
    let all = Set(0..<SessionPalette.colors.count)
    let i = SessionPalette.index(for: "x", taken: all)
    #expect((0..<SessionPalette.colors.count).contains(i))
}

@Test func saturationZeroIsGrey() {
    let grey = RGB(hex: 0x4F9CF9).saturated(0)
    #expect(abs(grey.r - grey.g) < 1e-9 && abs(grey.g - grey.b) < 1e-9)
}
