import SwiftUI
import CubiKit

/// `emphasis: loud` (experimental): a giant round Cubi, `NudgeMotion.loudHeightShare` of the screen's
/// height, rolls in from the right, stops in the middle making the effect's face under a speech
/// bubble (who, the message, the plugin's name), and rolls out to the left, all within the
/// `present`'s seconds. With Reduce Motion: the bubble over a still Cubi in the middle, fading in and out.
/// Nothing on the screen flashes; only the Cubi's own glow does, as on the card.
struct ServiceLoudView: View {
    let request: ServiceProtocol.Present
    let plugin: String
    /// The screen it covers, in points.
    let screen: CGSize
    let reduceMotion: Bool
    var frozenAt: Double? = nil
    @State private var start = Date()

    static let fade = 0.3

    var body: some View {
        if let frozenAt {
            frame(frozenAt)
        } else {
            TimelineView(.animation) { context in frame(context.date.timeIntervalSince(start)) }
        }
    }

    private var diameter: Double { screen.height * NudgeMotion.loudHeightShare }
    private var rgb: RGB { ServiceOverlay.cubiColor(request.color, effect: request.effect) }

    @ViewBuilder
    private func frame(_ t: Double) -> some View {
        if reduceMotion {
            still(t)
        } else {
            rolling(t)
        }
    }

    private func rolling(_ t: Double) -> some View {
        let roll = NudgeMotion.roll(at: t, total: request.seconds, width: screen.width, diameter: diameter)
        var pose = roll.holding ? NudgeMotion.pose(effect: request.effect, at: roll.heldFor, reduceMotion: false) : BotPose()
        pose.tilt += roll.angle
        // BotPainter fills 80 % of its canvas with the body.
        let side = diameter / 0.8
        let centerY = screen.height * 0.6
        let top = centerY - diameter / 2
        // The bubble over the Cubi, sparks and glow included: its words, and whose, stay readable.
        let gap = diameter * 0.18
        return ZStack {
            NudgeCubi(pose: pose, color: rgb,
                      glow: roll.holding && request.effect == "zap" ? NudgeMotion.glow(at: roll.heldFor) : 0)
                .frame(width: side, height: side)
                .position(x: roll.centerX, y: centerY - side * 0.08)
            if roll.holding {
                bubble(tail: .bottom)
                    .scaleEffect(NudgeMotion.pop(at: roll.heldFor, start: 0), anchor: .bottom)
                    .frame(width: screen.width, height: max(0, top - gap), alignment: .bottom)
                    .position(x: screen.width / 2, y: max(0, top - gap) / 2)
            }
        }
        .frame(width: screen.width, height: screen.height)
    }

    private func still(_ t: Double) -> some View {
        let opacity = max(0, min(1, t / Self.fade, (request.seconds - t) / Self.fade))
        return VStack(spacing: 14) {
            bubble(tail: .bottom)
            NudgeCubi(pose: NudgeMotion.pose(effect: request.effect, at: 0, reduceMotion: true), color: rgb)
                .frame(width: diameter * 0.6, height: diameter * 0.6)
        }
        .opacity(opacity)
        .frame(width: screen.width, height: screen.height)
    }

    /// Who, the message, and whose, in the white bubble the card uses, larger.
    private func bubble(tail: Edge) -> some View {
        NudgeBubble(title: ServiceOverlay.title(effect: request.effect, from: request.from), message: request.message,
                    plugin: plugin, tail: tail, scale: 1.6)
    }
}
