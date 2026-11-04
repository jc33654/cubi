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

    /// A one-line question from a plugin's card (the island has no text fields of its own).
    static func askForLine(_ prompt: String) -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "確定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
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
