import AppKit
import CubiKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController?
    private var statusBar: StatusBarController?
    private var coordinator: SessionCoordinator?
    private var settings: SettingsWindow?
    private let toolkit = ToolkitPanel()
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
        let settings = SettingsWindow(island: island.state, notifier: coordinator.notifier, ignored: coordinator.ignored,
                                      registry: coordinator.registry, toolkit: toolkit)
        self.settings = settings
        let statusBar = StatusBarController(island: island, notifier: coordinator.notifier,
                                            openSettings: { [settings] in settings.show() },
                                            openToolkit: { [toolkit] in toolkit.show() })
        self.statusBar = statusBar
        island.contextMenu = statusBar.menu
        coordinator.start()
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

    /// Clicking the app in the Dock/Finder while it runs also reveals the island.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        island?.showBriefly()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        island?.shutdown()
    }
}
