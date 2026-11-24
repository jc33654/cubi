import AppKit
import SwiftUI
import CubiKit

/// What a plugin service's `present` asks for (experimental): a small card in the bottom-right
/// corner of the screen under the mouse, for the seconds it asks (ServiceProtocol.presentSeconds),
/// with the effect's sound and its message if any. It never takes focus and lets clicks through.
/// The plugin's name is on it, so a service cannot pass it off as something of the system's.
@MainActor
final class ServiceOverlay {
    /// The panel; the card inside is as tall as its text needs, at the bottom.
    static let size = CGSize(width: 300, height: 160)

    private var panel: NSPanel?
    private var screensAsleep = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        })
    }

    /// nil when it is on screen; otherwise why not, as `presented` says it: "busy" (one is up, no
    /// queue) or "unavailable" (screen locked or asleep, no screen). `emphasis` is not drawn yet.
    func show(_ request: ServiceProtocol.Present, plugin: String) -> String? {
        let effect = request.effect
        guard panel == nil else { return "busy" }
        guard !screensAsleep, !Self.screenLocked() else { return "unavailable" }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first else { return "unavailable" }
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - Self.size.width - 16, y: visible.minY + 16, width: Self.size.width, height: Self.size.height)
        let panel = ServiceOverlayPanel(contentRect: frame)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // When the service could not shake the real window, the card shakes instead.
        panel.contentView = NSHostingView(rootView: ServiceOverlayView(
            effect: effect, from: request.from, plugin: plugin, message: request.message, color: request.color,
            shakes: effect == "shake" && !request.windowShaken, reduceMotion: reduceMotion))
        panel.orderFrontRegardless()
        Sounds.play(Self.cue(sound: Self.sound(for: effect)))
        self.panel = panel
        Task { @MainActor [weak self] in
            // Busy for all of it: the service times the next one by the same seconds.
            try? await Task.sleep(for: .milliseconds(Int(request.seconds * 1000)))
            panel.orderOut(nil)
            panel.contentView = nil
            self?.panel = nil
        }
        return nil
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

    private static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// Transparent, click-through, never key or main, on every Space.
private final class ServiceOverlayPanel: NSPanel {
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

/// The card, in the island's colours. `t` 0 is the still frame Reduce Motion gets. The knock timing
/// and the shake curve follow LAN Nudge's NudgeView (MIT), so the plugin feels like the app.
struct ServiceOverlayView: View {
    let effect: String
    let from: String
    let plugin: String
    var message: String? = nil
    /// SessionPalette index; nil keeps the effect's own colour.
    var color: Int? = nil
    let shakes: Bool
    let reduceMotion: Bool
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSince(start)
            card(t)
                .offset(x: shakes ? Self.shakeOffset(t) : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func card(_ t: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(accent)
                .scaleEffect(iconScale(t))
                .opacity(effect == "zap" && t > 0 && Int(t * 6).isMultiple(of: 2) ? 0.55 : 1)
                .frame(width: 34)
            // Every line clipped to itself: a service's text (combining marks, oversized glyphs) can
            // never reach another line, least of all the plugin's name, or leave the card.
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1).clipped()
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.88)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(color == nil ? Color.white.opacity(0.12) : accent.opacity(0.7)))
    }

    private static let maxWidth: CGFloat = ServiceOverlay.size.width

    private var icon: String {
        switch effect {
        case "knock": "hand.raised.fill"
        case "zap": "bolt.fill"
        default: "hand.point.right.fill"
        }
    }

    private var title: String {
        effect == "knock" ? "\(from) 在敲你的門" : "\(from) 戳了你一下"
    }

    private var accent: Color {
        guard let color, SessionPalette.colors.indices.contains(color) else { return effect == "knock" ? .orange : .yellow }
        let rgb = SessionPalette.colors[color]
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Three knocks at 0, 0.22 and 0.44 s.
    private func iconScale(_ t: Double) -> CGFloat {
        guard effect == "knock", t > 0 else { return 1 }
        let since = [0, 0.22, 0.44].map { t - $0 }.filter { $0 >= 0 }.min() ?? 1
        return since < 0.1 ? 1.18 : 1
    }

    /// About 9 Hz side to side, settling after about 1.1 s.
    static func shakeOffset(_ t: Double) -> CGFloat {
        let decay = max(0, 1 - t / 1.1)
        return CGFloat(sin(t * 2 * .pi * 9) * 14 * decay)
    }
}
