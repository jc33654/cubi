// The character's state machine and animation, free of any drawing code so it can be unit tested.
// The app advances it with a fixed step per drawn frame and renders `pose`.

import Foundation

public enum BotState: String, Sendable, CaseIterable, Codable {
    case idle, thinking, working, waiting, error, sleeping, happy, tired
}

public enum EyeShape: Sendable, Equatable {
    case pill, wide, flat, closedArc, happyArc, droop
}

public enum Badge: Sendable, Equatable {
    case none, dots, exclaim, question, zzz
}

/// Everything the painter needs for one frame. Offsets and sizes are fractions of the body size.
public struct BotPose: Sendable, Equatable {
    public var eyeOpen: Double = 1
    public var eyeWidth: Double = 0.16
    public var eyeHeight: Double = 0.22
    public var eyeShape: EyeShape = .pill
    public var lookX: Double = 0
    public var lookY: Double = 0
    public var bodyDX: Double = 0
    public var bodyDY: Double = 0
    public var scaleX: Double = 1
    public var scaleY: Double = 1
    public var tilt: Double = 0
    public var badge: Badge = .none
    public var badgePhase: Double = 0
    public var sweat: Bool = false
    public var sparks: Double = 0
    public var saturation: Double = 1
    public var pulse: Double = 0

    public init() {}
}

public struct BotModel: Sendable {
    public private(set) var state: BotState = .idle
    /// 0–100 from the status line; drives how tired the tired state looks.
    public var contextPercent: Double = 0
    /// Which badge `waiting` shows: `.exclaim` for approvals, `.question` for questions.
    public var waitingBadge: Badge = .exclaim
    public private(set) var time: Double = 0

    private var blinkStartedAt: Double? = nil
    private var nextBlinkAt: Double = 2.4
    private var impulseAt: Double = -10
    private var lookX: Double = 0
    private var lookY: Double = 0
    private var mouseX: Double = 0
    private var mouseY: Double = 0

    public init() {}

    public mutating func setState(_ new: BotState) {
        guard new != state else { return }
        state = new
        impulseAt = time
    }

    /// Where the pointer is relative to the character, each in -1…1.
    public mutating func setMouseLook(x: Double, y: Double) {
        mouseX = max(-1, min(1, x))
        mouseY = max(-1, min(1, y))
    }

    /// Advances the clock. `random` returns a value in 0..<1 and is injected so tests are deterministic.
    public mutating func update(dt: Double, random: () -> Double) {
        time += dt
        advanceBlink(random: random)
        let (tx, ty) = lookTarget
        let k = 1 - pow(0.0008, dt)
        lookX += (tx - lookX) * k
        lookY += (ty - lookY) * k
    }

    private var lookTarget: (Double, Double) {
        switch state {
        case .thinking: return (0.55, 0.55)
        case .sleeping: return (0, -0.6)
        case .tired:    return (mouseX * 0.3, -0.4)
        default:        return (mouseX, mouseY)
        }
    }

    private mutating func advanceBlink(random: () -> Double) {
        if state == .sleeping || state == .happy {
            blinkStartedAt = nil
            nextBlinkAt = time + 1
            return
        }
        if let started = blinkStartedAt {
            if time - started >= 0.2 {
                blinkStartedAt = nil
                // A second quick blink now and then reads as alive rather than mechanical.
                nextBlinkAt = time + (random() < 0.22 ? 0.23 : 2.2 + random() * 3.2)
            }
        } else if time >= nextBlinkAt {
            blinkStartedAt = time
        }
    }

    private var blinkOpen: Double {
        guard let started = blinkStartedAt else { return 1 }
        let elapsed = time - started
        if elapsed < 0.07 { return 1 - (elapsed / 0.07) * 0.94 }
        if elapsed < 0.2 { return 0.06 + ((elapsed - 0.07) / 0.13) * 0.94 }
        return 1
    }

    public var pose: BotPose {
        var p = BotPose()
        p.lookX = lookX
        p.lookY = lookY
        p.eyeOpen = blinkOpen
        let since = time - impulseAt
        let t = time

        switch state {
        case .idle:
            break
        case .thinking:
            p.badge = .dots
            p.badgePhase = t
            p.tilt = 0.06
        case .working:
            p.badge = .dots
            p.badgePhase = t * 1.6
            p.bodyDY = sin(t * 6) * 0.015
        case .waiting:
            p.eyeShape = .wide
            p.eyeHeight = 0.3
            p.badge = waitingBadge
            p.bodyDY = -abs(sin(t * 5.2)) * 0.07
        case .error:
            p.eyeShape = .flat
            p.eyeHeight = 0.08
            if since < 0.5 { p.bodyDX = sin(since * 40) * 0.04 * (1 - since / 0.5) }
        case .sleeping:
            p.eyeShape = .closedArc
            p.scaleY = 1 + sin(t * 1.8) * 0.035
            p.badge = .zzz
            p.badgePhase = t
        case .happy:
            p.eyeShape = .happyArc
            if since < 0.5 { p.bodyDY = -sin(since / 0.5 * .pi) * 0.12 }
            p.sparks = max(0, 1 - since / 0.8)
        case .tired:
            let severity = min(1, max(0, (contextPercent - 80) / 20))   // 0 at 80 %, 1 at 100 %
            p.eyeShape = .droop
            p.eyeOpen = blinkOpen * (0.6 - 0.25 * severity)
            p.sweat = true
            p.saturation = 0.65 - 0.2 * severity
            p.tilt = 0.08
            p.bodyDY = 0.03
            if contextPercent >= 90 { p.pulse = 0.5 + 0.5 * sin(t * 4) }
        }
        return p
    }
}
