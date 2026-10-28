import SwiftUI
import CubiKit

/// Draws one Cubi into a GraphicsContext. Shared by the live view and the icon renderer.
enum BotPainter {
    static func draw(_ pose: BotPose, color: RGB, in ctx: inout GraphicsContext, size: CGSize) {
        let base = color.saturated(pose.saturation)
        // The body sits in the lower 80 % of the canvas so badges, sparks and "z"s above it are not clipped.
        let w = size.width * 0.8 * pose.scaleX
        let h = size.height * 0.8 * pose.scaleY
        let cx = size.width / 2 + pose.bodyDX * size.width
        let cy = size.height * 0.58 + pose.bodyDY * size.height
        let body = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        let corner = w * 0.28

        var c = ctx
        if pose.tilt != 0 {
            c.translateBy(x: cx, y: cy)
            c.rotate(by: .radians(pose.tilt))
            c.translateBy(x: -cx, y: -cy)
        }

        // Body: colour with a soft top-light gradient, then an inner rim and a highlight.
        let bodyPath = Path(roundedRect: body, cornerRadius: corner)
        c.fill(bodyPath, with: .linearGradient(
            Gradient(colors: [swift(base.adjusted(by: 0.18)), swift(base), swift(base.adjusted(by: -0.12))]),
            startPoint: CGPoint(x: body.midX, y: body.minY),
            endPoint: CGPoint(x: body.midX, y: body.maxY)))
        c.stroke(bodyPath.insetBy(w * 0.03), with: .color(.black.opacity(0.18)), lineWidth: w * 0.06)
        let highlight = CGRect(x: body.minX + w * 0.12, y: body.minY + h * 0.08, width: w * 0.28, height: h * 0.12)
        c.fill(Path(roundedRect: highlight, cornerRadius: h * 0.06), with: .color(.white.opacity(0.28)))

        if pose.pulse > 0 {
            c.stroke(bodyPath, with: .color(.red.opacity(0.85 * pose.pulse)), lineWidth: max(1.5, w * 0.05))
        }

        drawEyes(pose, body: body, in: &c)
        drawBadge(pose, body: body, in: &c)

        if pose.sweat {
            let drop = CGRect(x: body.maxX - w * 0.14, y: body.minY + h * 0.18, width: w * 0.1, height: h * 0.16)
            c.fill(Path(ellipseIn: drop), with: .color(Color(red: 0.55, green: 0.8, blue: 1).opacity(0.9)))
        }
        if pose.sparks > 0 {
            let a = pose.sparks
            spark(at: CGPoint(x: body.minX - w * 0.1, y: body.minY + h * 0.1), r: w * 0.08, alpha: a, in: &c)
            spark(at: CGPoint(x: body.maxX + w * 0.12, y: body.minY + h * 0.3), r: w * 0.06, alpha: a, in: &c)
        }
    }

    private static func drawEyes(_ pose: BotPose, body: CGRect, in c: inout GraphicsContext) {
        let w = body.width, h = body.height
        let eyeW = w * pose.eyeWidth
        let eyeH = max(h * 0.03, h * pose.eyeHeight * pose.eyeOpen)
        let dx = pose.lookX * w * 0.06
        let dy = -pose.lookY * h * 0.05
        let eyeY = body.midY - h * 0.04 + dy
        let ink = Color(red: 0.08, green: 0.09, blue: 0.14)
        let centers = [CGPoint(x: body.midX - w * 0.2 + dx, y: eyeY), CGPoint(x: body.midX + w * 0.2 + dx, y: eyeY)]

        for (i, center) in centers.enumerated() {
            switch pose.eyeShape {
            case .pill, .wide, .flat:
                let r = CGRect(x: center.x - eyeW / 2, y: center.y - eyeH / 2, width: eyeW, height: eyeH)
                c.fill(Path(roundedRect: r, cornerRadius: min(eyeW, eyeH) / 2), with: .color(ink))
            case .droop:
                var r = c
                let sign: CGFloat = i == 0 ? -1 : 1
                r.translateBy(x: center.x, y: center.y)
                r.rotate(by: .radians(0.35 * sign))
                r.translateBy(x: -center.x, y: -center.y)
                let rect = CGRect(x: center.x - eyeW / 2, y: center.y - eyeH / 2, width: eyeW, height: eyeH)
                r.fill(Path(roundedRect: rect, cornerRadius: min(eyeW, eyeH) / 2), with: .color(ink))
            case .closedArc:
                var p = Path()
                p.addArc(center: CGPoint(x: center.x, y: center.y - eyeW * 0.2), radius: eyeW * 0.55,
                         startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                c.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1, h * 0.05), lineCap: .round))
            case .happyArc:
                var p = Path()
                p.addArc(center: CGPoint(x: center.x, y: center.y + eyeW * 0.25), radius: eyeW * 0.55,
                         startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                c.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1, h * 0.06), lineCap: .round))
            }
        }
    }

    private static func drawBadge(_ pose: BotPose, body: CGRect, in c: inout GraphicsContext) {
        let w = body.width, h = body.height
        let top = CGPoint(x: body.maxX - w * 0.05, y: body.minY - h * 0.02)
        switch pose.badge {
        case .none:
            break
        case .dots:
            for i in 0..<3 {
                let phase = sin(pose.badgePhase * 3 - Double(i) * 0.9)
                let alpha = 0.35 + 0.65 * max(0, phase)
                let r = w * 0.07
                let p = CGPoint(x: body.midX + CGFloat(i - 1) * w * 0.2, y: body.minY - h * 0.12)
                c.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.white.opacity(alpha)))
            }
        case .exclaim, .question:
            let text = pose.badge == .exclaim ? "!" : "?"
            let r = w * 0.17
            let circle = CGRect(x: top.x - r, y: top.y - r, width: 2 * r, height: 2 * r)
            c.fill(Path(ellipseIn: circle), with: .color(pose.badge == .exclaim ? Color.orange : Color.cyan))
            c.draw(Text(text).font(.system(size: r * 1.5, weight: .heavy)).foregroundStyle(.black), at: top)
        case .zzz:
            let bob = sin(pose.badgePhase * 1.5) * h * 0.04
            c.draw(Text("z").font(.system(size: h * 0.3, weight: .bold)).foregroundStyle(.white.opacity(0.85)),
                   at: CGPoint(x: body.maxX + w * 0.06, y: body.minY + h * 0.05 + bob))
            c.draw(Text("z").font(.system(size: h * 0.2, weight: .bold)).foregroundStyle(.white.opacity(0.6)),
                   at: CGPoint(x: body.maxX + w * 0.2, y: body.minY - h * 0.1 - bob))
        }
    }

    private static func spark(at p: CGPoint, r: CGFloat, alpha: Double, in c: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y - r)); path.addLine(to: CGPoint(x: p.x, y: p.y + r))
        path.move(to: CGPoint(x: p.x - r, y: p.y)); path.addLine(to: CGPoint(x: p.x + r, y: p.y))
        c.stroke(path, with: .color(.yellow.opacity(alpha)), style: StrokeStyle(lineWidth: max(1, r * 0.35), lineCap: .round))
    }

    static func swift(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }
}

private extension Path {
    func insetBy(_ d: CGFloat) -> Path {
        let b = boundingRect.insetBy(dx: d, dy: d)
        return Path(roundedRect: b, cornerRadius: b.width * 0.26)
    }
}
