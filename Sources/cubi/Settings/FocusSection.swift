import SwiftUI
import CubiKit

/// Settings → 專注: the switch, today's 專注獎勵, and the last 14 days.
struct FocusSection: View {
    @Bindable var focus: FocusRecorder
    @Environment(\.settingChanged) private var settingChanged

    var body: some View {
        DashCard(title: "專注獎勵", icon: "timer",
                 help: "session 在忙的時間每累積滿 25 分鐘，得到一個獎勵。多個 session 同時在忙只算一次；中間停頓不會歸零，每天午夜重算。Claude 自己跑的受限 session（AI 估點、回顧）不算。只存在這台電腦，不影響 Sprint 的工時。") {
            SettingRow(title: "計算專注獎勵", help: "打開後從那一刻開始算，關著的時間不補。關掉不會清掉已經記下的。") {
                switchToggle(reporting($focus.enabled, settingChanged))
            }
            let today = focus.log.today(now: Date().timeIntervalSinceReferenceDate)
            SettingRow(title: "今天") {
                HStack(spacing: 6) {
                    Image(systemName: FocusMark.symbol).foregroundStyle(Dash.warning)
                    Text("\(today.gears) 個").font(.system(size: 12, weight: .semibold))
                    Text("專注 \(today.busyText)" + (focus.enabled ? "，再 \(FocusLog.Day.text(today.untilNext.rounded(.up))) 下一個" : ""))
                        .foregroundStyle(.secondary)
                }
            }
        }
        DashCard(title: "最近 14 天", icon: "calendar") {
            let days = focus.log.recent(14, now: Date().timeIntervalSinceReferenceDate)
            let most = max(1, days.map(\.gears).max() ?? 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(days, id: \.date) { day in
                    HStack(spacing: 10) {
                        Text(String(day.date.dropFirst(5)).replacingOccurrences(of: "-", with: "/"))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Dash.warning.opacity(day.gears > 0 ? 0.8 : 0.15))
                                .frame(width: max(4, geo.size.width * CGFloat(day.gears) / CGFloat(most)))
                        }
                        .frame(height: 8)
                        HStack(spacing: 3) {
                            Image(systemName: FocusMark.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Dash.warning)
                            Text("\(day.gears)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 44, alignment: .trailing)
                        Text(day.busyText).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            .opacity(focus.enabled ? 1 : 0.5)
        }
    }
}
