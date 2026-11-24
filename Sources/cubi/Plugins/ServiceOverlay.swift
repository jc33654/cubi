import AppKit
import SwiftUI
import CubiKit

/// What a plugin service's `present` asks for (experimental): a small card in the bottom-right
/// corner of the screen under the mouse, or with `emphasis: loud` a giant Cubi across that screen
/// (ServiceLoudView), for the seconds it asks (ServiceProtocol.presentSeconds), with the effect's
/// sound and its message if any. It never takes focus and lets clicks through. The plugin's name is
/// on it, so a service cannot pass it off as something of the system's. It goes as soon as the
/// screen locks or sleeps.
@MainActor
final class ServiceOverlay {
    /// The panel; the card inside is as tall as its text needs, at the bottom.
    static let size = CGSize(width: 300, height: 160)

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
            panel = ServiceOverlayPanel(contentRect: CGRect(x: visible.maxX - Self.size.width - 16, y: visible.minY + 16,
                                                            width: Self.size.width, height: Self.size.height))
            // When the service could not shake the real window, the card shakes instead.
            panel.contentView = NSHostingView(rootView: ServiceOverlayView(
                effect: request.effect, from: request.from, plugin: plugin, message: request.message, color: request.color,
                shakes: request.effect == "shake" && !request.windowShaken, reduceMotion: reduceMotion))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        // The giant Cubi makes its face once it has rolled in: the sound comes with that, if it is
        // still up by then.
        let cue = Self.cue(sound: Self.sound(for: request.effect))
        let rolling = request.emphasis == .loud && !reduceMotion ? NudgeMotion.rollTime(total: request.seconds) : 0
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
        effect == "knock" ? "\(from) 在敲你的門" : "\(from) 戳了你一下"
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
    }
}

/// The card, in the island's colours. `frozenAt` draws one moment (the offline picture); with
/// Reduce Motion it is the still frame. The knock timing and the shake curve follow LAN Nudge's
/// NudgeView (MIT), so the plugin feels like the app.
struct ServiceOverlayView: View {
    let effect: String
    let from: String
    let plugin: String
    var message: String? = nil
    /// SessionPalette index; nil keeps the effect's own colour.
    var color: Int? = nil
    let shakes: Bool
    let reduceMotion: Bool
    var frozenAt: Double? = nil
    @State private var start = Date()

    var body: some View {
        if let frozenAt {
            frame(frozenAt)
        } else {
            TimelineView(.animation(paused: reduceMotion)) { context in
                frame(reduceMotion ? 0 : context.date.timeIntervalSince(start))
            }
        }
    }

    private func frame(_ t: Double) -> some View {
        card(t)
            .offset(x: shakes ? NudgeMotion.shakeOffset(at: t, reduceMotion: reduceMotion) : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func card(_ t: Double) -> some View {
        let rgb = ServiceOverlay.cubiColor(color, effect: effect)
        return HStack(spacing: 12) {
            NudgeCubi(pose: NudgeMotion.pose(effect: effect, at: t, reduceMotion: reduceMotion), color: rgb,
                      glow: effect == "zap" ? NudgeMotion.glow(at: t, reduceMotion: reduceMotion) : 0)
                .frame(width: 44, height: 44)
            // Every line clipped to itself: a service's text (combining marks, oversized glyphs) can
            // never reach another line, least of all the plugin's name, or leave the card.
            VStack(alignment: .leading, spacing: 3) {
                Text(ServiceOverlay.title(effect: effect, from: from)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).clipped()
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                        // 60 characters (ServiceProtocol.messageLimit) of the widest script fit whole.
                        .lineLimit(5)
                        .clipped()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(plugin).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).clipped()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: ServiceOverlay.size.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.88)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(color == nil ? Color.white.opacity(0.12) : BotPainter.swift(rgb).opacity(0.7)))
    }
}
