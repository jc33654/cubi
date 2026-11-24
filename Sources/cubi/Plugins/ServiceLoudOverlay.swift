import SwiftUI
import CubiKit

/// `emphasis: loud` (experimental): a giant round Cubi, `NudgeMotion.loudHeightShare` of the screen's
/// height, rolls in from the right, stops in the middle making the effect's face under a speech
/// bubble (who, the message, the plugin's name), and rolls out to the left, all within the
/// `present`'s seconds. With Reduce Motion: a large card in the middle that fades in and out, still.
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
                bubble()
                    .frame(width: screen.width, height: max(0, top - gap), alignment: .bottom)
                    .position(x: screen.width / 2, y: max(0, top - gap) / 2)
            }
        }
        .frame(width: screen.width, height: screen.height)
    }

    private func still(_ t: Double) -> some View {
        let opacity = max(0, min(1, t / Self.fade, (request.seconds - t) / Self.fade))
        return HStack(spacing: 28) {
            NudgeCubi(pose: NudgeMotion.pose(effect: request.effect, at: 0, reduceMotion: true), color: rgb)
                .frame(width: diameter * 0.5, height: diameter * 0.5)
            bubble(framed: false)
        }
        .padding(32)
        .frame(maxWidth: 760)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black.opacity(0.88)))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(BotPainter.swift(rgb).opacity(0.7), lineWidth: 2))
        .opacity(opacity)
        .frame(width: screen.width, height: screen.height)
    }

    /// Who, the message, and whose: each line clipped to itself, as on the card.
    private func bubble(framed: Bool = true) -> some View {
        let text = VStack(alignment: .leading, spacing: 8) {
            Text(ServiceOverlay.title(effect: request.effect, from: request.from)).font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white).lineLimit(1).clipped()
            if let message = request.message {
                Text(message).font(.system(size: 20)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(5).clipped().fixedSize(horizontal: false, vertical: true)
            }
            Text(plugin).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).clipped()
        }
        return Group {
            if framed {
                text
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.88)))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(BotPainter.swift(rgb).opacity(0.7), lineWidth: 2))
            } else {
                text.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
