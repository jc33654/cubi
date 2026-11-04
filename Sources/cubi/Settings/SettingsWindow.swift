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
        let view = SettingsView(hooks: model, island: island, registry: registry, notifier: notifier, ignored: ignored, timing: timing,
                                calendar: calendar, openTool: openTool)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Cubi 設定"
        let hosting = NSHostingView(rootView: view)
        // Keep the window's own size: a ScrollView reports no ideal size and would collapse it.
        hosting.sizingOptions = []
        w.contentView = hosting
        w.setContentSize(NSSize(width: 620, height: 600))
        w.minSize = NSSize(width: 560, height: 420)
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
