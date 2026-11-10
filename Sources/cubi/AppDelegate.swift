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
    private let linePrompt = LinePrompt()

    /// Posted by a second launch so the running copy reveals the island (there is no window to show).
    private static let showNotification = Notification.Name("cc.dotdot.cubi.show")
    /// Touched every second by the main run loop in all common modes (a dialog open still counts),
    /// so a second launch can tell a stuck copy from a busy one without asking it anything.
    nonisolated private static let heartbeatPath = CubiPaths.home.path + "/Library/Application Support/cubi/heartbeat"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only copies started before this one: a later one is still checking on this one.
        let started = NSRunningApplication.current.launchDate ?? .distantFuture
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: CubiInfo.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && ($0.launchDate ?? .distantPast) < started }
        guard others.isEmpty else { Task { await takeOverIfStuck(others) }; return }
        launch()
    }

    /// Opening Cubi while it runs shows the island. A copy whose heartbeat has not moved for 3 s is
    /// stuck (or an older build without one): it is force-quit and this launch carries on, so
    /// opening Cubi again (or 重開 Cubi) is the way out of a hang.
    private func takeOverIfStuck(_ others: [NSRunningApplication]) async {
        let pid = others[0].processIdentifier
        DistributedNotificationCenter.default().postNotificationName(Self.showNotification, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        let asked = Date()
        func beating() -> Bool {
            let touched = (try? FileManager.default.attributesOfItem(atPath: Self.heartbeatPath))?[.modificationDate] as? Date
            return touched.map { $0 > asked } ?? false
        }
        for _ in 0..<30 where !beating() { try? await Task.sleep(for: .milliseconds(100)) }
        if beating() {
            CubiLog.write("already running (pid \(pid)), asked it to show the island")
            NSApp.terminate(nil)
            return
        }
        CubiLog.write("already running (pid \(pid)) but its heartbeat stopped (stuck, or an older build): force-quitting it")
        others.forEach { $0.forceTerminate() }
        for _ in 0..<30 where !others.allSatisfy(\.isTerminated) { try? await Task.sleep(for: .milliseconds(100)) }
        guard others.allSatisfy(\.isTerminated) else {
            CubiLog.write("pid \(pid) did not quit; leaving it running and not starting a second copy")
            NSApp.terminate(nil)
            return
        }
        launch()
    }

    /// The folder may not exist yet on a first run (the coordinator makes it later), or someone
    /// deleted it: without the file a second launch would take a healthy copy for a stuck one.
    /// Only the first attempt logs a failure; the timer retries every second.
    nonisolated private static func makeHeartbeat(logFailure: Bool) {
        let url = URL(fileURLWithPath: heartbeatPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        } catch {
            if logFailure { CubiLog.write("heartbeat: cannot create \(heartbeatPath): \(error.localizedDescription)") }
        }
    }

    private func launch() {
        Self.makeHeartbeat(logFailure: true)
        RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { _ in
            if utimes(Self.heartbeatPath, nil) != 0 { Self.makeHeartbeat(logFailure: false) }
        }, forMode: .common)
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
        widgets.promptForInput = { [linePrompt] in await linePrompt.ask($0) }
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
