import SwiftUI
import CubiKit

// The pieces the nudge overlays share: the round Cubi and the speech bubble.

/// A round Cubi in a pose (NudgeMotion), with the zap's glow behind it.
struct NudgeCubi: View {
    let pose: BotPose
    let color: RGB
    var glow = 0.0

    /// The glow's size against the body, and its blur against the canvas: it reaches about
    /// `glowReach` × the canvas's width from the body's centre, past the canvas, so it is drawn
    /// outside it (a Canvas clips to itself).
    static let glowScale = 1.3
    static let glowBlur = 0.06
    static var glowReach: Double { 0.8 * glowScale / 2 + 2 * glowBlur }

    var body: some View {
        Canvas { ctx, size in
            BotPainter.draw(pose, color: color, shape: .circle, in: &ctx, size: size)
        }
        .background {
            if glow > 0 {
                GeometryReader { g in
                    // Where BotPainter puts the body, a little larger, softened.
                    let d = g.size.width * 0.8 * Self.glowScale
                    Circle().fill(.yellow.opacity(0.55 * glow))
                        .frame(width: d, height: d)
                        .blur(radius: g.size.width * Self.glowBlur)
                        .position(x: g.size.width / 2, y: g.size.height * 0.58)
                }
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
    }
}

/// The white speech bubble: who, the message, whose. White with dark text and a shadow, so it reads
/// on any desktop; every line clipped to itself, so a service's text never reaches the plugin's name.
struct NudgeBubble: View {
    let title: String
    var message: String? = nil
    let plugin: String
    var tail: Edge = .trailing
    var scale: CGFloat = 1
    var maxWidth: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            Text(title).font(.system(size: 14 * scale, weight: .semibold)).foregroundStyle(.black.opacity(0.88))
                .lineLimit(1).clipped()
            if let message {
                Text(message).font(.system(size: 12 * scale)).foregroundStyle(.black.opacity(0.78))
                    // 60 characters (ServiceProtocol.messageLimit) of the widest script fit whole.
                    .lineLimit(5).clipped().fixedSize(horizontal: false, vertical: true)
            }
            Text(plugin).font(.system(size: 10 * scale)).foregroundStyle(.black.opacity(0.5)).lineLimit(1).clipped()
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: maxWidth * scale, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).fill(.white))
        .clipShape(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .background(alignment: tail == .trailing ? .bottomTrailing : .bottomTrailing) { BubbleTail(edge: tail, scale: scale) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

/// The bubble's small tail toward the Cubi: on the right near the bottom, or under it near the right.
struct BubbleTail: View {
    let edge: Edge
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            if edge == .trailing {
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2)); p.addLine(to: CGPoint(x: 0, y: size.height))
            } else {
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0))
            }
            ctx.fill(p, with: .color(.white))
        }
        .frame(width: (edge == .trailing ? 9 : 16) * scale, height: (edge == .trailing ? 14 : 9) * scale)
        .offset(x: edge == .trailing ? 8 * scale : -22 * scale, y: edge == .trailing ? -14 * scale : 8 * scale)
    }
}
