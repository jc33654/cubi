import SwiftUI
import CubiKit

/// One animated Cubi. The model advances by real elapsed time, clamped so a pause or a stall
/// never produces one giant step (and the display's refresh rate does not change the tempo).
struct BotView: View {
    let bot: BotRuntime
    var paused: Bool

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let last = bot.lastFrame
                let dt = last == 0 ? 1.0 / 60 : min(0.1, max(0, now - last))
                bot.lastFrame = now
                bot.model.update(dt: dt, random: { Double.random(in: 0..<1) })
                BotPainter.draw(bot.model.pose, color: bot.color, in: &context, size: size)
            }
        }
        .accessibilityLabel(Text(bot.name))
    }
}
