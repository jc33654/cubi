import SwiftUI
import CubiKit

/// Right-click menu for one robot: shape and colour, remembered for this session only.
struct BotLookMenu: View {
    let bot: BotRuntime
    let state: IslandState

    var body: some View {
        Menu("形狀") {
            ForEach(BotShape.allCases, id: \.self) { shape in
                Button { state.setShape(shape == .square ? nil : shape, for: bot.id) } label: {
                    if bot.shape == shape { Label(shape.displayName, systemImage: "checkmark") } else { Text(shape.displayName) }
                }
            }
        }
        Menu("顏色") {
            let picked = state.looks.look(for: bot.id).colorIndex
            Button { state.setColorIndex(nil, for: bot.id) } label: {
                if picked == nil { Label("自動", systemImage: "checkmark") } else { Text("自動") }
            }
            Divider()
            ForEach(Array(SessionPalette.colors.enumerated()), id: \.offset) { i, rgb in
                Button { state.setColorIndex(i, for: bot.id) } label: {
                    Label {
                        Text(picked == i ? "✓ " + SessionPalette.names[i] : SessionPalette.names[i])
                    } icon: {
                        Image(nsImage: Self.swatch(rgb))
                    }
                }
            }
        }
    }

    private static func swatch(_ rgb: RGB) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            return true
        }
    }
}

/// A tiny filled outline of the robot's shape, for list rows.
struct ShapeSwatch: View {
    let shape: BotShape
    let color: RGB
    var size: CGFloat = 12

    var body: some View {
        Canvas { ctx, sz in
            let body = CGRect(x: sz.width * 0.08, y: sz.height * 0.08, width: sz.width * 0.84, height: sz.height * 0.84)
            ctx.fill(BotPainter.bodyPath(shape, in: body), with: .color(BotPainter.swift(color)))
        }
        .frame(width: size, height: size)
    }
}
