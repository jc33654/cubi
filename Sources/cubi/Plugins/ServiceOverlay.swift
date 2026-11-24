import AppKit
import SwiftUI

/// What a plugin service's `present` asks for (experimental): a small card in the bottom-right
/// corner of the screen under the mouse, for two seconds, with the effect's sound. It never takes
/// focus and lets clicks through. The plugin's name is on it, so a service cannot pass it off as
/// something of the system's.
@MainActor
final class ServiceOverlay {
    static let size = CGSize(width: 300, height: 110)
    static let duration: Duration = .seconds(2)

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
    /// queue) or "unavailable" (screen locked or asleep, no screen).
    func show(effect: String, from: String, plugin: String, windowShaken: Bool) -> String? {
        guard panel == nil else { return "busy" }
        guard !screensAsleep, !Self.screenLocked() else { return "unavailable" }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first else { return "unavailable" }
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - Self.size.width - 16, y: visible.minY + 16, width: Self.size.width, height: Self.size.height)
        let panel = ServiceOverlayPanel(contentRect: frame)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // When the service could not shake the real window, the card shakes instead.
        panel.contentView = NSHostingView(rootView: ServiceOverlayView(effect: effect, from: from, plugin: plugin,
                                                                       shakes: effect == "shake" && !windowShaken, reduceMotion: reduceMotion))
        panel.orderFrontRegardless()
        Sounds.play(Self.cue(sound: Self.sound(for: effect)))
        self.panel = panel
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.duration)
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
                .foregroundStyle(effect == "knock" ? Color.orange : Color.yellow)
                .scaleEffect(iconScale(t))
                .opacity(effect == "zap" && t > 0 && Int(t * 6).isMultiple(of: 2) ? 0.55 : 1)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(plugin).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12)))
    }

    private static let maxWidth: CGFloat = ServiceOverlay.size.width

    private var icon: String {
        switch effect {
        case "knock": "hand.raised.fill"
        case "zap": "bolt.fill"
        default: "hand.point.right.fill"
        }
    }

    private var message: String {
        effect == "knock" ? "\(from) 在敲你的門" : "\(from) 戳了你一下"
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
