import SwiftUI
import AppKit

/// The settings window's dashboard look, light and dark: the same palette as the panels' style kit
/// (`panel.style: "cubi"`), so Cubi's own pages and its plugins' read as one thing.
enum Dash {
    static let background = adaptive(light: 0xF3F4F6, dark: 0x0F1115)
    static let sidebar = adaptive(light: 0xFFFFFF, dark: 0x14171C)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x181B21)
    static let border = adaptive(light: 0xE5E7EB, dark: 0x262A33)
    static let accent = adaptive(light: 0x2563EB, dark: 0x3B82F6)
    static let good = adaptive(light: 0x16A34A, dark: 0x22C55E)
    static let warning = adaptive(light: 0xD97706, dark: 0xF59E0B)
    static let danger = adaptive(light: 0xDC2626, dark: 0xEF4444)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                 blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A white (or dark) card: icon and title on the left, optional controls on the right, then the body.
/// The long explanation, if any, sits behind an ⓘ.
struct DashCard<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    var help: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Dash.accent).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let help { InfoTip(text: help) }
                Spacer()
                accessory
            }
            content
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Dash.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Dash.border))
    }
}

extension DashCard where Accessory == EmptyView {
    init(title: String, icon: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, help: help, accessory: { EmptyView() }, content: content)
    }
}

/// Label on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let help { InfoTip(text: help) }
            Spacer(minLength: 16)
            control
        }
        .frame(minHeight: 22)
    }
}

@MainActor
func switchToggle(_ isOn: Binding<Bool>) -> some View {
    Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
}

struct InfoTip: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).help(text)
    }
}

/// A coloured dot and a word: 已安裝, 未串接, 需要權限….
struct StatusPill: View {
    enum Tone { case good, warning, danger, neutral }
    let text: String
    let tone: Tone

    private var color: Color {
        switch tone {
        case .good: Dash.good
        case .warning: Dash.warning
        case .danger: Dash.danger
        case .neutral: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Small grey capsule for a plugin's traits (內建, 審批, 資訊窗…).
struct TraitTag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }
}
