import AppKit
import ServiceManagement
import CubiKit

/// The menubar item: an icon now, usage numbers from Phase 4.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let island: IslandController
    private let notifier: Notifier
    private let loginItem = NSMenuItem(title: "登入時啟動", action: #selector(toggleLogin), keyEquivalent: "")
    private let notifyItem = NSMenuItem(title: "系統通知", action: #selector(toggleNotifications), keyEquivalent: "")
    private let pinItem = NSMenuItem(title: "保持顯示", action: #selector(togglePinned), keyEquivalent: "")
    private let floatItem = NSMenuItem(title: "浮動視窗（可拖到任何螢幕）", action: #selector(toggleFloating), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "音效", action: #selector(toggleSounds), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "設定…", action: #selector(showSettings), keyEquivalent: ",")
    /// One per enabled tool plugin, after 設定…; rebuilt whenever the menu opens.
    private var toolItems: [NSMenuItem] = []
    private let registry: PluginRegistry
    /// Shared with the island's right-click menu.
    let menu: NSMenu

    private let openSettings: () -> Void
    private let openTool: (String) -> Void
    private let openNewSession: () -> Void

    init(island: IslandController, notifier: Notifier, registry: PluginRegistry, openSettings: @escaping () -> Void,
         openTool: @escaping (String) -> Void, openNewSession: @escaping () -> Void) {
        self.island = island
        self.notifier = notifier
        self.registry = registry
        self.openSettings = openSettings
        self.openTool = openTool
        self.openNewSession = openNewSession
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "cube.fill", accessibilityDescription: "Cubi")
            image?.isTemplate = true
            button.image = image
        }
        fill(menu)
        menu.delegate = self
        item.menu = menu
    }

    private func fill(_ menu: NSMenu) {
        let show = NSMenuItem(title: "顯示 / 收起", action: #selector(toggleIsland), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let newSession = NSMenuItem(title: "開新 session…", action: #selector(showNewSession), keyEquivalent: "n")
        newSession.target = self
        menu.addItem(newSession)
        pinItem.target = self
        pinItem.state = island.state.pinned ? .on : .off
        menu.addItem(pinItem)
        floatItem.target = self
        menu.addItem(floatItem)

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
        settingsItem.target = self
        menu.addItem(settingsItem)
        refreshToolItems(in: menu)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "結束 Cubi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        floatItem.state = island.isFloating ? .on : .off
        pinItem.state = island.state.pinned ? .on : .off
        refreshToolItems(in: menu)
    }

    private func refreshToolItems(in menu: NSMenu) {
        toolItems.forEach { menu.removeItem($0) }
        toolItems = registry.tools.filter { registry.isEnabled($0.id) }.map { tool in
            let item = NSMenuItem(title: tool.displayName, action: #selector(openToolItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.id
            return item
        }
        let at = menu.index(of: settingsItem) + 1
        for (i, item) in toolItems.enumerated() { menu.insertItem(item, at: at + i) }
    }

    @objc private func openToolItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { openTool(id) }
    }

    @objc private func toggleIsland() {
        island.toggleFromMenu()
    }

    @objc private func showSettings() { openSettings() }
    @objc private func showNewSession() { openNewSession() }

    @objc private func toggleSounds() {
        Sounds.enabled.toggle()
        soundItem.state = Sounds.enabled ? .on : .off
    }

    @objc private func toggleFloating() {
        island.setPlacement(island.isFloating ? .notch : .floating)
    }

    @objc private func togglePinned() {
        island.setPinned(!island.state.pinned)
        pinItem.state = island.state.pinned ? .on : .off
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
