import AppKit
import ServiceManagement
import CubiKit

/// The menubar item: an icon now, usage numbers from Phase 4.
@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let island: IslandController
    private let notifier: Notifier
    private let loginItem = NSMenuItem(title: "登入時啟動", action: #selector(toggleLogin), keyEquivalent: "")
    private let notifyItem = NSMenuItem(title: "系統通知", action: #selector(toggleNotifications), keyEquivalent: "")
    private let pinItem = NSMenuItem(title: "保持顯示", action: #selector(togglePinned), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "音效", action: #selector(toggleSounds), keyEquivalent: "")
    /// Shared with the island's right-click menu.
    let menu: NSMenu

    init(island: IslandController, notifier: Notifier) {
        self.island = island
        self.notifier = notifier
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "cube.fill", accessibilityDescription: "Cubi")
            image?.isTemplate = true
            button.image = image
        }
        fill(menu)
        item.menu = menu
    }

    private func fill(_ menu: NSMenu) {
        let show = NSMenuItem(title: "顯示 / 收起", action: #selector(toggleIsland), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        pinItem.target = self
        pinItem.state = island.state.pinned ? .on : .off
        menu.addItem(pinItem)

        let demo = NSMenuItem(title: "Demo 狀態", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for state in BotState.allCases {
            let entry = NSMenuItem(title: state.rawValue, action: #selector(setDemoState(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = state.rawValue
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        let removeDemo = NSMenuItem(title: "移除示範機器人", action: #selector(removeDemo), keyEquivalent: "")
        removeDemo.target = self
        sub.addItem(removeDemo)
        demo.submenu = sub
        menu.addItem(demo)

        menu.addItem(.separator())
        notifyItem.target = self
        notifyItem.state = notifier.enabled ? .on : .off
        menu.addItem(notifyItem)
        soundItem.target = self
        soundItem.state = Sounds.enabled ? .on : .off
        menu.addItem(soundItem)
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "結束 Cubi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleIsland() {
        island.toggleFromMenu()
    }

    @objc private func setDemoState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let state = BotState(rawValue: raw) else { return }
        island.setDemoState(state)
    }

    @objc private func toggleSounds() {
        Sounds.enabled.toggle()
        soundItem.state = Sounds.enabled ? .on : .off
    }

    @objc private func togglePinned() {
        island.setPinned(!island.state.pinned)
        pinItem.state = island.state.pinned ? .on : .off
    }

    @objc private func removeDemo() {
        island.removeDemoBot()
    }

    @objc private func toggleNotifications() {
        notifier.enabled.toggle()
        notifyItem.state = notifier.enabled ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            CubiLog.write("login item change failed: \(error)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
