import AppKit
import SwiftUI

/// One settings window, created on demand.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = HookSetupModel()
    private let island: IslandState
    private let notifier: Notifier
    private let ignored: IgnoredDirectories
    private let timing: SleepTiming
    private let registry: PluginRegistry
    private let calendar: SystemCalendar
    private let openTool: (String) -> Void

    init(island: IslandState, notifier: Notifier, ignored: IgnoredDirectories, timing: SleepTiming,
         registry: PluginRegistry, calendar: SystemCalendar, openTool: @escaping (String) -> Void) {
        self.island = island
        self.notifier = notifier
        self.ignored = ignored
        self.timing = timing
        self.registry = registry
        self.calendar = calendar
        self.openTool = openTool
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let notifier = notifier
        let view = SettingsView(hooks: model, island: island, registry: registry,
                                notifications: Binding(get: { notifier.enabled }, set: { notifier.enabled = $0 }), ignored: ignored, timing: timing,
                                calendar: calendar, openTool: openTool)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Cubi 設定"
        let hosting = NSHostingView(rootView: view)
        // Keep the window's own size: a ScrollView reports no ideal size and would collapse it.
        hosting.sizingOptions = []
        w.contentView = hosting
        w.setContentSize(Self.size)
        w.minSize = NSSize(width: 720, height: 480)
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    static let size = NSSize(width: 820, height: 600)

    /// `--render-settings`: one page as the window shows it, this machine's real settings,
    /// drawn off screen. Nothing is pressed; no Notifier (it would take over the notification centre).
    static func render(page: SettingsView.Page, dark: Bool, to url: URL) -> Bool {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     hasNotch: true, notchWidth: 190, notchHeight: 32)
        let island = IslandState(geometry: geometry)
        island.persists = false
        let view = SettingsView(hooks: HookSetupModel(), island: island, registry: PluginRegistry(),
                                notifications: .constant(UserDefaults.standard.bool(forKey: Notifier.enabledKey)),
                                ignored: IgnoredDirectories(), timing: SleepTiming(), calendar: SystemCalendar(),
                                openTool: { _ in }, page: page)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        w.contentView = hosting
        w.setContentSize(size)
        w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        w.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI's onAppear (hook status, calendar status) land before the shot.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            return true
        } catch {
            FileHandle.standardError.write(Data("cubi: cannot write \(url.path): \(error)\n".utf8))
            return false
        }
    }
}

/// Sessions whose cwd starts with one of these never get a robot.
@MainActor
final class IgnoredDirectories {
    static let key = "ignoredDirectoryPrefixes"
    var prefixes: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    func ignores(_ cwd: String?) -> Bool {
        guard let cwd else { return false }
        return prefixes.contains { cwd.hasPrefix(($0 as NSString).expandingTildeInPath) }
    }
}
