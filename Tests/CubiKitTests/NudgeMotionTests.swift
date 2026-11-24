import Testing
import Foundation
@testable import CubiKit

// Inputs: the effect names (ServiceProtocol.effects), NudgeMotion's own lengths and limits, and
// ServiceProtocol.presentSeconds' ends for the total; the screen 1512×982 is the one the offline
// picture draws on (IconRenderer), its height × loudHeightShare the diameter.

private typealias M = NudgeMotion
private let effects = ServiceProtocol.effects.sorted()
private let width = 1512.0, diameter = 982.0 * M.loudHeightShare

/// Times the glow turns on within [from, from + 1) s, sampled every millisecond.
private func lightings(from: Double, reduceMotion: Bool = false) -> Int {
    var count = 0, was = M.glow(at: from - 0.001, reduceMotion: reduceMotion) > 0
    for i in 0..<1000 {
        let on = M.glow(at: from + Double(i) / 1000, reduceMotion: reduceMotion) > 0
        if on && !was { count += 1 }
        was = on
    }
    return count
}

@Test func nothingFlashesMoreThanTwiceASecondAndNothingWithReduceMotion() {
    #expect(M.maxFlashesPerSecond < 3)
    for start in stride(from: -0.5, through: M.zapLength, by: 0.05) {
        #expect(lightings(from: start) <= Int(M.maxFlashesPerSecond))
        #expect(lightings(from: start, reduceMotion: true) == 0)
    }
    // It does light: the zap is seen.
    #expect(lightings(from: 0) >= 1)
}

@Test func posesStartAtTheFirstFrameAndRestAfterTheirEnd() {
    for effect in effects {
        // Before the start is the start.
        #expect(M.pose(effect: effect, at: -1, reduceMotion: false) == M.pose(effect: effect, at: 0, reduceMotion: false))
        // Past the end: the resting Cubi, the same however late.
        let end = max(M.zapLength, M.shakeLength, (M.knocks.last ?? 0) + M.knockLength)
        #expect(M.pose(effect: effect, at: end, reduceMotion: false) == M.pose(effect: effect, at: end + 100, reduceMotion: false))
        #expect(M.pose(effect: effect, at: end, reduceMotion: false).eyeShape == .pill)
        // Reduce Motion: never moves.
        for t in [0, 0.05, 0.3, 1, 5] {
            let p = M.pose(effect: effect, at: t, reduceMotion: true)
            #expect(p.bodyDX == 0 && p.bodyDY == 0 && p.tilt == 0 && p.scaleX == 1 && p.sparks == 0)
            #expect(M.shakeOffset(at: t, reduceMotion: true) == 0)
        }
    }
    // The zap's crossed eyes, still or not, for its length; the knocks on their beats only.
    #expect(M.pose(effect: "zap", at: 0, reduceMotion: true).eyeShape == .cross)
    #expect(M.pose(effect: "zap", at: M.zapLength - 0.01, reduceMotion: false).eyeShape == .cross)
    for beat in M.knocks {
        #expect(M.pose(effect: "knock", at: beat, reduceMotion: false).scaleX > 1)
        #expect(M.pose(effect: "knock", at: beat + M.knockLength, reduceMotion: false).scaleX == 1)
    }
    #expect(M.shakeOffset(at: M.shakeLength) == 0 && M.shakeOffset(at: -1) == 0)
}

@Test func theGiantCubiRollsInStopsUprightAndRollsOut() {
    let r = diameter / 2
    for total in [ServiceProtocol.presentSeconds.lowerBound, ServiceProtocol.defaultPresentSeconds, 8, ServiceProtocol.presentSeconds.upperBound] {
        let travel = M.rollTime(total: total)
        #expect(travel > 0 && travel <= M.maxRoll && travel * 2 < total)
        let first = M.roll(at: 0, total: total, width: width, diameter: diameter)
        // Starts just off the right edge, rolling; before the start is the start.
        #expect(first.centerX == width + r && !first.holding)
        #expect(M.roll(at: -1, total: total, width: width, diameter: diameter) == first)
        // In the middle, upright, from arrival to departure.
        let arrived = M.roll(at: travel, total: total, width: width, diameter: diameter)
        #expect(arrived.holding && arrived.centerX == width / 2 && arrived.angle == 0 && arrived.heldFor == 0)
        let leaving = M.roll(at: total - travel - 0.001, total: total, width: width, diameter: diameter)
        #expect(leaving.holding && abs(leaving.heldFor - (total - 2 * travel - 0.001)) < 1e-9)
        // Ends just off the left edge; after the end is the end.
        let last = M.roll(at: total, total: total, width: width, diameter: diameter)
        #expect(last.centerX == -r && !last.holding)
        #expect(M.roll(at: total + 100, total: total, width: width, diameter: diameter) == last)
        // Rolling left it turns one way all along: the angle only goes down.
        var previous = first.angle
        for i in 1...200 {
            let a = M.roll(at: total * Double(i) / 200, total: total, width: width, diameter: diameter).angle
            #expect(a <= previous + 1e-9)
            previous = a
        }
    }
    // No time at all: off the left edge, not stuck in the middle.
    #expect(M.roll(at: 0, total: 0, width: width, diameter: diameter).centerX == -r)
}
