import SwiftUI

/// Settings → 睡眠: how long before a robot sleeps, and before it goes to the 晚安 zone.
struct SleepSection: View {
    @Bindable var timing: SleepTiming

    var body: some View {
        DashCard(title: "睡眠", icon: "moon.zzz",
                 help: "調短立刻生效；調長不會叫醒已經沉睡的，但自動進晚安區的會回來。手動「去睡覺」的不受影響；狀態列持續回報不算動靜。") {
            SettingRow(title: "多久沒動靜進入沉睡") {
                Picker("", selection: $timing.sleepMinutes) {
                    ForEach(SleepTiming.sleepChoices, id: \.self) { Text("\($0) 分鐘").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(title: "沉睡多久自動進晚安區") {
                Picker("", selection: $timing.restHours) {
                    ForEach(SleepTiming.restChoices, id: \.self) { Text(SleepTiming.restLabel($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}
