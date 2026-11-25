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

    // MARK: - Entrances (the frameless overlay)

    /// The knock falls in from the upper right and bounces like a ping-pong ball; the zap rolls in
    /// from the right edge; the shake peeks in from it. Short, as they count in the `present`'s seconds.
    public static let bounceLength = 0.75
    public static let rollInLength = 0.6
    public static let peekLength = 0.35
    /// The last this many seconds fade out.
    public static let fadeLength = 0.25

    /// Never more of the `present`'s seconds than this share goes to coming in, so a short one (1 s)
    /// still has its knocks within it.
    public static let entranceShare = 0.35

    /// When the effect itself (its face, its sound) starts: once the Cubi is in; at once with Reduce Motion.
    public static func entrance(effect: String, total: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        let full: Double
        switch effect {
        case "zap": full = rollInLength
        case "shake": full = peekLength
        default: full = bounceLength
        }
        return min(full, max(0, total) * entranceShare)
    }

    /// The entering Cubi against where it rests, in points, for a Cubi `diameter` across: `dx` to the
    /// right of it, `dy` above it (negative), `angle` as it rolls, `squash` its height as it lands.
    public struct Entering: Sendable, Equatable {
        public var dx = 0.0
        public var dy = 0.0
        public var angle = 0.0
        public var squash = 1.0
        public init() {}
    }

    public static func enter(effect: String, at t: Double, total: Double, diameter: Double, reduceMotion: Bool) -> Entering {
        var e = Entering()
        let t = max(0, t), r = diameter / 2, length = entrance(effect: effect, total: total, reduceMotion: reduceMotion)
        guard length > 0, t < length else { return e }
        let u = t / length
        switch effect {
        case "zap":
            e.dx = diameter * 4.5 * (1 - u) * (1 - u)
            e.angle = r > 0 ? e.dx / r : 0
        case "shake":
            e.dx = diameter * (1 - u) * (1 - u)
        default:
            e.dx = diameter * 4 * (1 - u) * (1 - u)
            e.angle = r > 0 ? e.dx / r * 0.3 : 0
            // Three arcs, each lower, the first falling from above; a squash as it touches down.
            let arcs: [(start: Double, end: Double, height: Double)] = [(0, 0.42, 2.2), (0.42, 0.76, 0.8), (0.76, 1, 0.28)]
            for (i, arc) in arcs.enumerated() where u >= arc.start && u < arc.end {
                let s = (u - arc.start) / (arc.end - arc.start)
                e.dy = -diameter * arc.height * (i == 0 ? 1 - s * s : 4 * s * (1 - s))
                if s > 0.9 || (i > 0 && s < 0.1) { e.squash = 0.86 }
            }
        }
        return e
    }

    /// A bubble's scale as it pops out at `start`: 0 before, a little past 1 on the way, then 1.
    public static func pop(at t: Double, start: Double, length: Double = 0.25) -> Double {
        let u = (t - start) / length
        guard u > 0 else { return 0 }
        guard u < 1 else { return 1 }
        return 1 + 2.2 * pow(u - 1, 3) + 1.2 * pow(u - 1, 2)
    }

    /// 1, then down to 0 over the last `fadeLength` of `total`.
    public static func fade(at t: Double, total: Double) -> Double {
        max(0, min(1, (total - t) / fadeLength))
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
