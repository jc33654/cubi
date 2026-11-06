import AppKit
import CubiKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController?
    private var statusBar: StatusBarController?
    private var coordinator: SessionCoordinator?
    private var settings: SettingsWindow?
    private var toolPanels: ToolPanels?
    private var ticker: PluginTicker?
    private var showObserver: NSObjectProtocol?

    /// Posted by a second launch so the running copy reveals the island (there is no window to show).
    private static let showNotification = Notification.Name("cc.dotdot.cubi.show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: CubiInfo.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            CubiLog.write("already running (pid \(others[0].processIdentifier)), asking it to show the island")
            DistributedNotificationCenter.default().postNotificationName(Self.showNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.mainMenu()
        Sounds.prewarm()

        let island = IslandController()
        self.island = island
        let coordinator = SessionCoordinator(island: island)
        self.coordinator = coordinator
        let toolPanels = ToolPanels(registry: coordinator.registry)
        self.toolPanels = toolPanels
        let widgets = SessionWidgetStore(registry: coordinator.registry)
        widgets.input = { [weak coordinator] in coordinator?.sessionInput(for: $0) }
        widgets.promptForInput = Self.askForLine
        island.state.widgets = widgets
        island.state.onOpenTool = { [toolPanels, weak coordinator] tool, session in
            toolPanels.show(tool, session: coordinator?.sessionInput(for: session))
        }
        let calendar = SystemCalendar()
        let ticker = PluginTicker(registry: coordinator.registry, calendar: calendar) { [weak coordinator] in coordinator?.tickInput() }
        self.ticker = ticker
        let settings = SettingsWindow(island: island.state, notifier: coordinator.notifier, ignored: coordinator.ignored,
                                      timing: coordinator.timing, registry: coordinator.registry, calendar: calendar,
                                      openTool: { [toolPanels] in toolPanels.show($0) })
        self.settings = settings
        let newSession = NewSessionWindow(recent: coordinator.recentProjects)
        coordinator.newSessionWindow = newSession
        let statusBar = StatusBarController(island: island, notifier: coordinator.notifier, registry: coordinator.registry,
                                            openSettings: { [settings] in settings.show() },
                                            openTool: { [toolPanels] in toolPanels.show($0) },
                                            openNewSession: { [newSession] in newSession.show() })
        self.statusBar = statusBar
        island.contextMenu = statusBar.menu
        coordinator.start()
        ticker.start()
        // Where development left project-local hooks behind; the settings window offers to clean them.
        if UserDefaults.standard.stringArray(forKey: HookSetupModel.projectLocalKey) == nil {
            UserDefaults.standard.set(["~/Documents/cubi"], forKey: HookSetupModel.projectLocalKey)
        }
        if !((try? HookSetup.status())?.hooksInstalled ?? false) || CommandLine.arguments.contains("--settings") { settings.show() }

        showObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.showNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.island?.showBriefly() }
        }

        island.showBriefly()
    }

    /// A menu-bar app shows no menu bar, but key equivalents only arrive through one: without it,
    /// text fields get no ⌘X ⌘C ⌘V ⌘A ⌘Z and windows no ⌘W —
    /// pasting a ticket number into a dialog or a panel did nothing.
    private static func mainMenu() -> NSMenu {
        let edit = NSMenu(title: "編輯")
        // undo:/redo: with the colon: that is what windows answer (UndoManager.undo has none).
        edit.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "編輯", action: nil, keyEquivalent: "")
        item.submenu = edit
        // ⌘W closes the settings window or a panel (the island is not closable). No ⌘Q: after a click
        // the island is the key window while another app still looks frontmost, so ⌘Q meant for that
        // app would quit Cubi. The status-bar menu has 結束.
        let app = NSMenu(title: "Cubi")
        app.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let appItem = NSMenuItem(title: "Cubi", action: nil, keyEquivalent: "")
        appItem.submenu = app
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(item)
        return main
    }

    /// A one-line question from a plugin's card (the island has no text fields of its own).
    static func askForLine(_ prompt: String) -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "確定")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Clicking the app in the Dock/Finder while it runs also reveals the island.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        island?.showBriefly()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ticker?.stop()
        coordinator?.stop()
        island?.shutdown()
    }
}
