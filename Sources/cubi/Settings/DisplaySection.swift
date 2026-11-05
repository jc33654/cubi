import SwiftUI
import ServiceManagement
import CubiKit

/// Settings → 顯示: the island, sounds, notifications, login item.
struct DisplaySection: View {
    @Bindable var island: IslandState
    let notifications: Binding<Bool>

    @State private var soundsOn = Sounds.enabled
    @State private var notificationsOn: Bool
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    // Starting values come in here, not in onAppear: setting them there would count as a change and
    // write back (and ask for notification permission again) on every visit to this page.
    init(island: IslandState, notifications: Binding<Bool>) {
        self.island = island
        self.notifications = notifications
        _notificationsOn = State(initialValue: notifications.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashCard(title: "島", icon: "capsule") {
                SettingRow(title: "保持顯示", help: "島不收回，休息時停在 compact") {
                    switchToggle($island.pinned)
                }
                SettingRow(title: "滑入就展開", help: "關掉的話，滑入只停在 compact，點一下才展開。保持顯示或浮動時才有作用。") {
                    switchToggle($island.expandOnHover).disabled(!island.pinned && island.placement != .floating)
                }
                SettingRow(title: "機器人大小") {
                    Picker("", selection: $island.botSizeChoice) {
                        ForEach(IslandState.BotSizeChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            DashCard(title: "提醒與啟動", icon: "bell") {
                SettingRow(title: "音效") {
                    switchToggle($soundsOn).onChange(of: soundsOn) { _, v in Sounds.enabled = v }
                }
                SettingRow(title: "系統通知", help: "需要通知權限，預設關") {
                    switchToggle($notificationsOn).onChange(of: notificationsOn) { _, v in notifications.wrappedValue = v }
                }
                SettingRow(title: "登入時啟動") {
                    switchToggle($loginOn).onChange(of: loginOn) { _, v in
                        do { v ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { CubiLog.write("login item: \(error)") }
                        loginOn = SMAppService.mainApp.status == .enabled
                    }
                }
            }
        }
    }
}
