import Foundation

/// How a service's `present` moves its Cubi (experimental): the pose for each effect at a time, and
/// the giant Cubi's roll for `emphasis: loud`. Pure, so every frame can be checked. Times are seconds
/// from the start; before it is the first frame, after the end the last.
///
/// Light: nothing flashes more than `maxFlashesPerSecond` times a second (under the 3 a second that
/// photosensitivity guidance draws the line at), and with Reduce Motion nothing moves or flashes.
public enum NudgeMotion {
    public static let maxFlashesPerSecond = 2.0
    /// Three knocks, on the sound's beats (LAN Nudge's NudgeView timing), each a short lean forward.
    public static let knocks: [Double] = [0, 0.22, 0.44]
    public static let knockLength = 0.1
    /// The zap: crossed eyes, a jitter and a glow that comes and goes, then back to normal.
    public static let zapLength = 1.2
    /// The shake: about 9 Hz side to side (a movement, not a flash), settling after `shakeLength`.
    public static let shakeLength = 1.1

    /// The Cubi's pose for `effect` at `t`.
    public static func pose(effect: String, at t: Double, reduceMotion: Bool) -> BotPose {
        var p = BotPose()
        p.eyeShape = .pill
        let t = max(0, t)
        switch effect {
        case "zap":
            // Crossed eyes stay for the zap even when still: they are the expression, not a motion.
            guard t < zapLength else { return p }
            p.eyeShape = .cross
            p.eyeWidth = 0.2
            p.eyeHeight = 0.2
            guard !reduceMotion else { return p }
            let decay = 1 - t / zapLength
            p.bodyDX = sin(t * 2 * .pi * 12) * 0.025 * decay
            p.sparks = glow(at: t)
        case "shake":
            guard !reduceMotion, t < shakeLength else { return p }
            p.tilt = sin(t * 2 * .pi * 9) * 0.12 * (1 - t / shakeLength)
        default:
            guard !reduceMotion, knocks.contains(where: { t >= $0 && t < $0 + knockLength }) else { return p }
            p.scaleX = 1.12
            p.scaleY = 1.12
            p.bodyDY = -0.02
        }
        return p
    }

    /// The zap's glow, 0 or 1: on for the first half of each `1 / maxFlashesPerSecond` period, so it
    /// lights at most that many times a second; off after the zap and with Reduce Motion.
    public static func glow(at t: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, t >= 0, t < zapLength else { return 0 }
        let period = 1 / maxFlashesPerSecond
        return t.truncatingRemainder(dividingBy: period) < period / 2 ? 1 : 0
    }

    /// The card's side-to-side offset for a shake, in points.
    public static func shakeOffset(at t: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, t >= 0, t < shakeLength else { return 0 }
        return sin(t * 2 * .pi * 9) * 14 * (1 - t / shakeLength)
    }

    // MARK: - The giant Cubi (emphasis: loud)

    /// Its size against the screen's height.
    public static let loudHeightShare = 0.4

    public struct Roll: Sendable, Equatable {
        /// The centre's x, in points from the screen's left edge.
        public var centerX: Double
        /// Radians as it turns rolling left (anticlockwise, so falling), 0 upright in the middle.
        public var angle: Double
        /// Stopped in the middle, making its face: from when it arrives until it leaves.
        public var holding: Bool
        /// Seconds since it stopped, for the effect's pose (0 while it rolls).
        public var heldFor: Double
    }

    /// Rolling in from the right takes this share of the time, at most `maxRoll` seconds; so does
    /// rolling out to the left.
    public static let rollShare = 0.25
    public static let maxRoll = 0.8

    public static func rollTime(total: Double) -> Double { min(maxRoll, max(0, total) * rollShare) }

    /// Where the giant Cubi is at `t` of `total` seconds on a screen `width` wide, `diameter` across:
    /// in from just past the right edge, eased to a stop in the middle, then out past the left edge.
    public static func roll(at t: Double, total: Double, width: Double, diameter: Double) -> Roll {
        let r = diameter / 2
        let start = width + r, middle = width / 2, end = -r
        let travel = rollTime(total: total)
        let t = min(max(0, t), max(0, total))
        let x: Double
        let holding: Bool
        var heldFor = 0.0
        if travel > 0, t < travel {
            let u = t / travel
            x = start + (middle - start) * (1 - (1 - u) * (1 - u))
            holding = false
        } else if t < total - travel {
            x = middle
            holding = true
            heldFor = t - travel
        } else {
            let u = travel > 0 ? (t - (total - travel)) / travel : 1
            // Exactly off the edge at the end, not a rounding short of it.
            x = t >= total || u >= 1 ? end : middle + (end - middle) * (u * u)
            holding = false
        }
        // Rolling turns it by the distance over the radius, measured from the middle so it faces
        // the viewer while it stops there.
        return Roll(centerX: x, angle: r > 0 ? (x - middle) / r : 0, holding: holding, heldFor: heldFor)
    }
}
