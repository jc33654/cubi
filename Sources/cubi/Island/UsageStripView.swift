import SwiftUI
import CubiKit

/// Plan usage: two bars with reset times. Shown at the top of the expanded island.
struct UsageStripView: View {
    let usage: StatuslineInfo?

    var body: some View {
        if let usage, usage.fiveHour != nil || usage.sevenDay != nil {
            HStack(spacing: 14) {
                if let w = usage.fiveHour { bar(title: "5h", window: w) }
                if let w = usage.sevenDay { bar(title: "7d", window: w) }
                if let cost = usage.costUSD {
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        } else {
            Text("還沒有用量資料（statusline 尚未串接）")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 4)
        }
    }

    private func bar(title: String, window: UsageWindow) -> some View {
        let pct = max(0, min(100, window.usedPercent))
        let reset = UsageFormat.resetLabel(resetsAt: window.resetsAt).map { "(\($0))" } ?? ""
        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(Self.levelColor(pct)).frame(width: geo.size.width * pct / 100)
                }
            }
            .frame(width: 70, height: 6)
            Text("\(Int(pct))% \(reset)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    static func levelColor(_ pct: Double) -> Color {
        switch UsageFormat.level(pct) {
        case .ok: return Color(red: 0.31, green: 0.84, blue: 0.55)
        case .warn: return Color(red: 0.96, green: 0.65, blue: 0.14)
        case .hot: return Color(red: 0.95, green: 0.33, blue: 0.37)
        }
    }
}
