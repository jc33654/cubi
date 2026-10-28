import AppKit
import SwiftUI
import CubiKit

/// Renders the app icon from the character itself, so the repo carries no image assets.
enum IconRenderer {
    private struct IconView: View {
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 1024 * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.19), Color(red: 0.05, green: 0.05, blue: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(1024 * 0.04)
                Canvas { context, size in
                    var pose = BotPose()
                    pose.lookX = 0.15
                    pose.lookY = 0.1
                    BotPainter.draw(pose, color: SessionPalette.colors[0], in: &context, size: size)
                }
                .frame(width: 1024 * 0.62, height: 1024 * 0.62)
            }
            .frame(width: 1024, height: 1024)
        }
    }

    @MainActor
    static func render(to path: String) -> Bool {
        writePNG(ImageRenderer(content: IconView()), scale: 1, to: path)
    }

    /// The island as the panel would show it, over a mid-grey background, at 2× for inspection.
    @MainActor
    static func renderIsland(mode: String, botState: String, to path: String) -> Bool {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     hasNotch: true, notchWidth: 190, notchHeight: 32)
        let state = IslandState(geometry: geometry)
        switch mode {
        case "hidden": state.mode = .hidden
        case "compact": state.mode = .compact
        case "expanded": state.mode = .expanded
        default:
            FileHandle.standardError.write(Data("cubi: unknown mode \(mode)\n".utf8))
            return false
        }
        guard let bs = BotState(rawValue: botState) else {
            FileHandle.standardError.write(Data("cubi: unknown bot state \(botState)\n".utf8))
            return false
        }
        for (i, name) in ["alpha", "beta", "gamma"].enumerated() {
            let bot = BotRuntime(id: name, name: name, color: SessionPalette.colors[i * 3])
            bot.model.setState(i == 0 ? bs : .idle)
            if bs == .tired { bot.model.contextPercent = 92 }
            bot.model.update(dt: 0.3, random: { 0.5 })
            state.bots.append(bot)
        }
        let view = IslandRootView(state: state, onTap: {})
            .frame(width: IslandPanel.size.width, height: 220, alignment: .top)
            .background(Color(white: 0.35))
        return writePNG(ImageRenderer(content: view), scale: 2, to: path)
    }

    @MainActor
    private static func writePNG<V: View>(_ renderer: ImageRenderer<V>, scale: CGFloat, to path: String) -> Bool {
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("cubi: render failed\n".utf8))
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(Int(image.size.width))×\(Int(image.size.height)))")
            return true
        } catch {
            FileHandle.standardError.write(Data("cubi: cannot write \(path): \(error)\n".utf8))
            return false
        }
    }
}
