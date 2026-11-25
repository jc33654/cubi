import AppKit
import SwiftUI
import CubiKit

/// What a plugin service's `present` asks for (experimental): a round Cubi coming into the bottom-right
/// corner of the screen under the mouse with a speech bubble, no frame (the knock bounces in, the zap
/// rolls in, the shake peeks in from the edge), or with `emphasis: loud` a giant Cubi across that screen
/// (ServiceLoudView), for the seconds it asks (ServiceProtocol.presentSeconds), with the effect's
/// sound and its message if any. It never takes focus and lets clicks through. The plugin's name is
/// on it, so a service cannot pass it off as something of the system's. It goes as soon as the
/// screen locks or sleeps.
@MainActor
final class ServiceOverlay {
    /// The panel, against the right and bottom of the visible frame (never over the Dock or the menu
    /// bar): room above for the bounce and at the edge for the roll and the peek. The window clips what
    /// is outside it, so nothing is drawn on a screen next to this one.
    static let size = CGSize(width: 420, height: 300)

    private var panel: NSPanel?
    private var closing: Task<Void, Never>?
    private var screensAsleep = false
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.close()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        })
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// nil when it is on screen; otherwise why not, as `presented` says it: "busy" (one is up, no
    /// queue) or "unavailable" (screen locked or asleep, no screen).
    func show(_ request: ServiceProtocol.Present, plugin: String) -> String? {
        guard panel == nil else { return "busy" }
        guard !screensAsleep, !Self.screenLocked() else { return "unavailable" }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first else { return "unavailable" }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel: NSPanel
        if request.emphasis == .loud {
            panel = ServiceOverlayPanel(contentRect: screen.frame)
            panel.contentView = NSHostingView(rootView: ServiceLoudView(request: request, plugin: plugin, screen: screen.frame.size,
                                                                        reduceMotion: reduceMotion))
        } else {
            let visible = screen.visibleFrame
            panel = ServiceOverlayPanel(contentRect: CGRect(x: visible.maxX - Self.size.width, y: visible.minY,
                                                            width: Self.size.width, height: Self.size.height))
            panel.contentView = NSHostingView(rootView: ServiceOverlayView(request: request, plugin: plugin, reduceMotion: reduceMotion))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        // The Cubi makes its face once it is in: the sound comes with that, if it is still up by then.
        let cue = Self.cue(sound: Self.sound(for: request.effect))
        let rolling = request.emphasis == .loud
            ? (reduceMotion ? 0 : NudgeMotion.rollTime(total: request.seconds))
            : NudgeMotion.entrance(effect: request.effect, total: request.seconds, reduceMotion: reduceMotion)
        if rolling > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + rolling) { [weak self] in
                MainActor.assumeIsolated { if self?.panel === panel { Sounds.play(cue) } }
            }
        } else {
            Sounds.play(cue)
        }
        closing = Task { @MainActor [weak self] in
            // Busy for all of it: the service times the next one by the same seconds. Cancelled or
            // not, the wait ends in closing this panel.
            try? await Task.sleep(for: .milliseconds(Int(request.seconds * 1000)))
            self?.close(panel)
        }
        return nil
    }

    /// Off screen now (`shown`: only if that one is still up).
    private func close(_ shown: NSPanel? = nil) {
        guard let panel, shown == nil || shown === panel else { return }
        closing?.cancel()
        closing = nil
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    /// The sound an effect makes (ServiceProtocol.effects to ServiceProtocol.sounds).
    static func sound(for effect: String) -> String {
        effect == "shake" ? "thud" : effect
    }

    /// One of ServiceProtocol.sounds as a cue.
    static func cue(sound: String) -> Sounds.Cue {
        switch sound {
        case "knock": .knock
        case "zap": .zap
        default: .thud
        }
    }

    /// The Cubi's colour: the service's palette index, or the effect's own (amber knock, yellow otherwise).
    static func cubiColor(_ index: Int?, effect: String) -> RGB {
        SessionPalette.colors[index.flatMap { SessionPalette.colors.indices.contains($0) ? $0 : nil } ?? (effect == "knock" ? 1 : 7)]
    }

    static func title(effect: String, from: String) -> String {
        switch effect {
        case "knock": "\(from) 在敲你的門"
        case "shake": "\(from) 震了你一下"
        default: "\(from) 戳了你一下"
        }
    }

    private static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// Transparent, click-through, never key or main, on every Space and over full-screen apps.
final class ServiceOverlayPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A round Cubi in a pose (NudgeMotion), with the zap's glow behind it.
struct NudgeCubi: View {
    let pose: BotPose
    let color: RGB
    var glow = 0.0

    var body: some View {
        Canvas { ctx, size in
            if glow > 0 {
                // Where BotPainter puts the body, a little larger, softened.
                let d = size.width * 0.8 * 1.3
                let halo = CGRect(x: size.width / 2 - d / 2, y: size.height * 0.58 - d / 2, width: d, height: d)
                var c = ctx
                c.addFilter(.blur(radius: size.width * 0.06))
                c.fill(Path(ellipseIn: halo), with: .color(.yellow.opacity(0.55 * glow)))
            }
            BotPainter.draw(pose, color: color, shape: .circle, in: &ctx, size: size)
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

/// The frameless nudge: the Cubi comes in (NudgeMotion.enter), the bubble pops out once it is in,
/// the effect's face follows, and the whole fades over the last moment of its seconds. `frozenAt`
/// draws one moment (the offline picture); with Reduce Motion, the still frame.
struct ServiceOverlayView: View {
    let request: ServiceProtocol.Present
    let plugin: String
    let reduceMotion: Bool
    var frozenAt: Double? = nil
    @State private var start = Date()

    static let diameter: CGFloat = 60

    var body: some View {
        if let frozenAt {
            frame(frozenAt)
        } else {
            TimelineView(.animation(paused: reduceMotion)) { context in
                frame(reduceMotion ? 0 : context.date.timeIntervalSince(start))
            }
        }
    }

    private var effect: String { request.effect }
    private var entrance: Double { NudgeMotion.entrance(effect: effect, total: request.seconds, reduceMotion: reduceMotion) }

    private func frame(_ t: Double) -> some View {
        let side = Self.diameter / 0.8
        let enter = NudgeMotion.enter(effect: effect, at: t, total: request.seconds, diameter: Self.diameter, reduceMotion: reduceMotion)
        let since = max(0, t - entrance)
        var pose = NudgeMotion.pose(effect: effect, at: since, reduceMotion: reduceMotion)
        pose.tilt += enter.angle
        pose.scaleY *= enter.squash
        pose.scaleX *= 2 - enter.squash
        // The shake: the Cubi wobbles itself when the service could not shake the real window.
        let wobble = effect == "shake" && !request.windowShaken ? NudgeMotion.shakeOffset(at: since, reduceMotion: reduceMotion) * 0.6 : 0
        if effect == "shake" && request.windowShaken { pose.tilt = enter.angle }
        let cubi = NudgeCubi(pose: pose, color: ServiceOverlay.cubiColor(request.color, effect: effect),
                             glow: effect == "zap" ? NudgeMotion.glow(at: since, reduceMotion: reduceMotion) : 0)
            .frame(width: side, height: side)
            .offset(x: enter.dx + wobble, y: enter.dy)
        let popped = reduceMotion ? 1 : NudgeMotion.pop(at: t, start: entrance)
        let bubble = NudgeBubble(title: ServiceOverlay.title(effect: effect, from: request.from), message: request.message,
                                 plugin: plugin, tail: effect == "zap" ? .bottom : .trailing)
            .scaleEffect(popped, anchor: effect == "zap" ? .bottomTrailing : .trailing)
            .opacity(popped > 0 ? 1 : 0)
        return Group {
            switch effect {
            case "zap":
                VStack(alignment: .trailing, spacing: 2) {
                    // Off the edge a little, so its right corners show however wide it gets.
                    bubble.padding(.trailing, 12)
                    cubi.padding(.trailing, 18)
                }
                .padding(.bottom, 8)
            case "shake":
                // Peeking: a third of it past the screen's edge.
                HStack(alignment: .center, spacing: 0) {
                    bubble.padding(.trailing, 10)
                    cubi.offset(x: side * 0.3)
                }
                .padding(.bottom, 40)
            default:
                HStack(alignment: .bottom, spacing: 4) {
                    bubble.padding(.bottom, 14)
                    cubi
                }
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            }
        }
        .opacity(reduceMotion ? 1 : NudgeMotion.fade(at: t, total: request.seconds))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
