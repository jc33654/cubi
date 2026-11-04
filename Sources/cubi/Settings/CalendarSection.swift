import SwiftUI
import AppKit

/// Settings → 行事曆: permission and which calendar plugins' work stretches go to.
struct CalendarSection: View {
    @Bindable var calendar: SystemCalendar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("行事曆").font(.headline)
            Text("有 tick hook 的工具插件（例如 sprint）可以把工作時段寫成事件，由系統同步到 Google 等帳號。只寫入，不讀你的行程；事件標「空閒」，不擋別人約會議。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            switch calendar.status {
            case .fullAccess:
                HStack {
                    Picker("寫入哪個行事曆", selection: Binding(
                        get: { calendar.calendarID ?? "" },
                        set: { calendar.calendarID = $0.isEmpty ? nil : $0 })) {
                        Text("未選擇").tag("")
                        ForEach(calendar.calendars) { Text($0.name).tag($0.id) }
                    }
                    Button("重新載入") { calendar.refresh() }
                }
                if calendar.calendarID != nil, !calendar.isReady {
                    Text("選的行事曆已不存在，請重選。").font(.system(size: 11)).foregroundStyle(.red)
                }
                Text("建議在 Google 日曆另外建一本「工作紀錄」，別寫進主行事曆；分享出去的行事曆別人看得到事件內容。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .notDetermined:
                Button("允許存取行事曆") { Task { await calendar.requestAccess() } }
            default:
                // Once denied, macOS never asks again; only the system settings can turn it on.
                HStack {
                    Text("沒有完整的行事曆存取權限").foregroundStyle(.red)
                    Button("打開系統設定") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    Button("重新檢查") { calendar.refresh() }
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: 480, alignment: .leading)
        .onAppear { calendar.refresh() }
    }
}
