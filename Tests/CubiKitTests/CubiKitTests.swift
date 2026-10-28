import Testing
@testable import CubiKit

@Test func protocolVersionIsStable() {
    #expect(CubiInfo.protocolVersion == 1)
}
