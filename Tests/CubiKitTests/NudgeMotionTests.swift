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

// Batch 70: the frameless overlay's entrances. Totals are ServiceProtocol.presentSeconds' ends and
// the default; the diameter is ServiceOverlayView's 60.
@Test func entrancesFinishWithinTheirSecondsAndRestAfter() {
    let d = 60.0
    for total in [ServiceProtocol.presentSeconds.lowerBound, ServiceProtocol.defaultPresentSeconds, ServiceProtocol.presentSeconds.upperBound] {
        for effect in effects {
            let length = M.entrance(effect: effect, total: total, reduceMotion: false)
            #expect(length > 0 && length <= total * M.entranceShare)
            // Before the start is the start; from its end on, at rest, however late.
            #expect(M.enter(effect: effect, at: -1, total: total, diameter: d, reduceMotion: false)
                    == M.enter(effect: effect, at: 0, total: total, diameter: d, reduceMotion: false))
            for t in [length, total, total + 100] {
                #expect(M.enter(effect: effect, at: t, total: total, diameter: d, reduceMotion: false) == M.Entering())
            }
            // It starts away from its place: off to the right.
            #expect(M.enter(effect: effect, at: 0, total: total, diameter: d, reduceMotion: false).dx > 0)
            // With Reduce Motion: at rest from the first frame, the face at once.
            #expect(M.entrance(effect: effect, total: total, reduceMotion: true) == 0)
            #expect(M.enter(effect: effect, at: 0, total: total, diameter: d, reduceMotion: true) == M.Entering())
        }
        // The knocks come after the bounce and are over before the end, even at 1 s.
        let knocksEnd = M.entrance(effect: "knock", total: total, reduceMotion: false) + (M.knocks.last ?? 0) + M.knockLength
        #expect(knocksEnd <= total)
        // The bounce never sinks below its resting place; the roll turns one way only.
        var previous = Double.infinity
        for i in 0...200 {
            let t = M.entrance(effect: "zap", total: total, reduceMotion: false) * Double(i) / 200
            #expect(M.enter(effect: "knock", at: t * M.bounceLength / M.rollInLength, total: total, diameter: d, reduceMotion: false).dy <= 0)
            let angle = M.enter(effect: "zap", at: t, total: total, diameter: d, reduceMotion: false).angle
            #expect(angle <= previous + 1e-9)
            previous = angle
        }
    }
}

@Test func bubblesPopAndEverythingFadesAtTheEnd() {
    #expect(M.pop(at: 0.4, start: 0.5) == 0 && M.pop(at: 0.5, start: 0.5) == 0)
    #expect(M.pop(at: 0.75, start: 0.5) == 1 && M.pop(at: 9, start: 0.5) == 1)
    var top = 0.0
    for i in 0...100 { top = max(top, M.pop(at: 0.5 + 0.25 * Double(i) / 100, start: 0.5)) }
    #expect(top > 1 && top < 1.2)
    for total in [ServiceProtocol.presentSeconds.lowerBound, ServiceProtocol.presentSeconds.upperBound] {
        #expect(M.fade(at: 0, total: total) == 1 && M.fade(at: total - M.fadeLength, total: total) == 1)
        #expect(M.fade(at: total, total: total) == 0 && M.fade(at: total + 1, total: total) == 0)
    }
}
