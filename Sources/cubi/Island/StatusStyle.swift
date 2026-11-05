import SwiftUI
import CubiKit

/// Colours and words for the detail card and plugins' sections: one palette that reads on the
/// island's black. Green, amber and red are the usage strip's, so a card never shows two greens.
@MainActor
enum StatusStyle {
    static let good = UsageStripView.levelColor(0)
    static let warning = UsageStripView.levelColor(50)
    static let danger = UsageStripView.levelColor(100)
    static let info = Color(red: 0.42, green: 0.66, blue: 1.0)
    static let neutral = Color.white.opacity(0.55)
    static let thinking = Color(red: 0.72, green: 0.58, blue: 1.0)

    static func color(_ tone: PluginIO.WidgetOutput.Tone) -> Color {
        switch tone {
        case .good: return good
        case .warning: return warning
        case .danger: return danger
        case .info: return info
        case .neutral: return neutral
        }
    }

    /// A robot's state in a word and a colour; `stateLabel` is the raw `BotState` name.
    static func state(_ stateLabel: String, resting: Bool) -> (text: String, color: Color) {
        if resting { return ("晚安", .white.opacity(0.35)) }
        switch BotState(rawValue: stateLabel) {
        case .working: return ("工作中", info)
        case .thinking: return ("思考中", thinking)
        case .waiting: return ("等你", warning)
        case .error: return ("出錯", danger)
        case .happy: return ("完成", good)
        case .tired: return ("快滿了", warning)
        case .sleeping: return ("沉睡", .white.opacity(0.35))
        case .idle, nil: return ("閒置", neutral)
        }
    }

    /// A plugin clock's reading. Counting down: `剩 1h 5m`, and in the last hour `剩 12:40` so
    /// the final minute is not "0m"; below zero `超 …`. Counting up: `00:12:40`, `−00:05:00`
    /// while still below zero.
    static func reading(_ seconds: Double, down: Bool) -> String {
        let s = Int(abs(seconds).rounded(.down))
        let hms = String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        guard down else { return (seconds < 0 ? "−" : "") + hms }
        let amount = s >= 3600 ? SessionDetail.duration(Double(s)) : String(format: "%02d:%02d", s / 60, s % 60)
        return (seconds < 0 ? "超 " : "剩 ") + amount
    }
}

/// The state as a coloured dot and word.
struct StateChip: View {
    let label: String
    let resting: Bool

    var body: some View {
        let s = StatusStyle.state(label, resting: resting)
        HStack(spacing: 4) {
            Circle().fill(s.color).frame(width: 6, height: 6)
            Text(s.text).font(.system(size: 10, weight: .semibold)).foregroundStyle(s.color)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(s.color.opacity(0.14)))
    }
}

/// A small square icon button for the island's black cards; the label is the tooltip.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .white.opacity(0.75)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Whether this system knows the symbol (a plugin may name one that does not exist).
    static func exists(_ symbol: String) -> Bool {
        if let known = known[symbol] { return known }
        let found = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        known[symbol] = found
        return found
    }

    /// Looked up once per name: a card with a clock redraws every second.
    @MainActor private static var known: [String: Bool] = [:]
}
