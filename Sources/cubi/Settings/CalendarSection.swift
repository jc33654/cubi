import SwiftUI
import AppKit

/// Settings → 行事曆: permission and which calendar plugins' work stretches go to.
struct CalendarSection: View {
    @Bindable var calendar: SystemCalendar
    @Environment(\.settingChanged) private var settingChanged

    var body: some View {
        DashCard(title: "工作時段寫進行事曆", icon: "calendar",
                 help: "有定時 hook 的工具插件（例如 sprint）會把工作時段寫成事件，由系統同步到 Google 等帳號。只寫入，不讀你的行程；事件標「空閒」，不擋別人約會議。") {
            switch calendar.status {
            case .fullAccess:
                SettingRow(title: "權限") { StatusPill(text: "已允許", tone: .good) }
                SettingRow(title: "寫入哪個行事曆", help: "建議另外建一本「工作紀錄」，別寫進主行事曆；分享出去的行事曆別人看得到事件內容。") {
                    Picker("", selection: Binding(
                        get: { calendar.calendarID ?? "" },
                        set: { calendar.calendarID = $0.isEmpty ? nil : $0; settingChanged() })) {
                        Text("未選擇").tag("")
                        ForEach(calendar.calendars) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("重新載入")
                }
                if calendar.calendarID != nil, !calendar.isReady {
                    Text("選的行事曆已不存在，請重選。").foregroundStyle(Dash.danger)
                }
            case .notDetermined:
                SettingRow(title: "權限") {
                    StatusPill(text: "還沒問過", tone: .neutral)
                    Button("允許存取") { Task { await calendar.requestAccess() } }
                }
            default:
                // Once denied, macOS never asks again; only the system settings can turn it on.
                SettingRow(title: "權限") {
                    StatusPill(text: "沒有完整存取權", tone: .danger)
                    Button("打開系統設定") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("重新檢查")
                }
            }
        }
        .onAppear { calendar.refresh() }
    }
}
