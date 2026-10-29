import SwiftUI
import CubiKit

/// Allow / Always / Deny for one tool call.
struct ApprovalCardView: View {
    let card: PendingCard
    let title: String
    let detail: String
    let canAlways: Bool
    let waitingCount: Int
    let decide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(BotPainter.swift(card.color))
                    .frame(width: 12, height: 12)
                Text(card.sessionName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("想要" + title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if waitingCount > 0 {
                    Text("還有 \(waitingCount) 件")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
            }
            Text(detail.isEmpty ? "（沒有細節）" : detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                CardButton(title: "拒絕", role: .deny) { decide(.deny) }
                Spacer()
                if canAlways {
                    CardButton(title: "總是允許", role: .secondary) { decide(.always) }
                }
                CardButton(title: "允許", role: .primary) { decide(.allow) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

struct CardButton: View {
    enum Role { case primary, secondary, deny }
    let title: String
    let role: Role
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(role == .primary ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
    }

    private var fill: Color {
        switch role {
        case .primary: return Color(red: 0.31, green: 0.84, blue: 0.55)
        case .secondary: return .white.opacity(0.18)
        case .deny: return Color(red: 0.95, green: 0.33, blue: 0.37).opacity(0.85)
        }
    }
}
