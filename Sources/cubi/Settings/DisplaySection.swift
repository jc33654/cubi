import SwiftUI
import ServiceManagement
import CubiKit

/// Settings → 顯示: the island, sounds, notifications, login item.
struct DisplaySection: View {
    @Bindable var island: IslandState
    let notifications: Binding<Bool>
    let notificationsDenied: () async -> Bool

    @State private var soundsOn = Sounds.enabled
    @State private var notificationsOn: Bool
    @State private var denied = false
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @Environment(\.settingChanged) private var settingChanged

    // Starting values come in here, not in onAppear: setting them there would count as a change and
    // write back (and ask for notification permission again) on every visit to this page.
    init(island: IslandState, notifications: Binding<Bool>, notificationsDenied: @escaping () async -> Bool) {
        self.island = island
        self.notifications = notifications
        self.notificationsDenied = notificationsDenied
        _notificationsOn = State(initialValue: notifications.wrappedValue)
    }

    private func checkPermission() async {
        denied = notificationsOn ? await notificationsDenied() : false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashCard(title: "島", icon: "capsule") {
                SettingRow(title: "保持顯示", help: "島不收回，休息時停在 compact") {
                    switchToggle(reporting($island.pinned, settingChanged))
                }
                SettingRow(title: "滑入就展開", help: "關掉的話，滑入只停在 compact，點一下才展開。保持顯示或浮動時才有作用。") {
                    switchToggle(reporting($island.expandOnHover, settingChanged)).disabled(!island.pinned && island.placement != .floating)
                }
                SettingRow(title: "機器人大小") {
                    Picker("", selection: reporting($island.botSizeChoice, settingChanged)) {
                        ForEach(IslandState.BotSizeChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            DashCard(title: "提醒與啟動", icon: "bell") {
                SettingRow(title: "音效") {
                    switchToggle($soundsOn).onChange(of: soundsOn) { _, v in Sounds.enabled = v; settingChanged() }
                }
                SettingRow(title: "系統通知", help: "需要通知權限，預設關") {
                    if notificationsOn && denied {
                        StatusPill(text: "沒有權限", tone: .danger)
                        Button("打開系統設定") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                    // Switching on asks first (the setter); the check after it then waits for the answer.
                    switchToggle($notificationsOn).onChange(of: notificationsOn) { _, v in
                        notifications.wrappedValue = v
                        settingChanged()
                        Task { await checkPermission() }
                    }
                }
                // On the page, and again whenever Cubi comes back (say, from System Settings).
                .task {
                    await checkPermission()
                    for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                        await checkPermission()
                    }
                }
                SettingRow(title: "登入時啟動") {
                    switchToggle($loginOn).onChange(of: loginOn) { _, v in
                        // Writing the real status back below triggers this again (say, register
                        // answered "needs approval"): that one must not undo the request.
                        guard v != (SMAppService.mainApp.status == .enabled) else { return }
                        do { v ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { CubiLog.write("login item: \(error)") }
                        loginOn = SMAppService.mainApp.status == .enabled
                        if loginOn == v { settingChanged() }   // not when it needs approval or failed
                    }
                }
            }
        }
    }
}
