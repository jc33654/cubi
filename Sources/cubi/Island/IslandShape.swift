import SwiftUI

/// The black island: square top corners (it merges with the notch / screen edge), rounded bottom
/// corners. Width, height and radius animate.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), radius) }
        set { width = newValue.first.first; height = newValue.first.second; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let x0 = rect.midX - width / 2
        let x1 = rect.midX + width / 2
        let y0 = rect.minY
        let y1 = rect.minY + height
        let r = min(radius, height / 2, width / 2)

        var p = Path()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x1, y: y0))
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addArc(center: CGPoint(x: x1 - r, y: y1 - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}
