import SwiftUI
import CubiKit

/// The last Edit/Write of a session, as coloured unified-diff lines.
struct DiffCardView: View {
    let sessionName: String
    let color: RGB
    let summary: EditSummary
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(BotPainter.swift(color)).frame(width: 12, height: 12)
                Text(sessionName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(summary.path)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("+\(summary.added)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Self.addedColor)
                Text("−\(summary.removed)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Self.removedColor)
            }
            Group {
                if summary.lines.count > 30 {
                    ScrollView(.vertical) { lines }.frame(height: 220)
                } else {
                    lines
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in row(line) }
            if summary.truncated {
                Text("…（只顯示前 \(EditSummaryBuilder.maxLines) 行）")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ line: DiffLine) -> some View {
        let (prefix, fg, bg): (String, Color, Color) = switch line.kind {
        case .added:   ("+", Self.addedColor, Self.addedColor.opacity(0.12))
        case .removed: ("-", Self.removedColor, Self.removedColor.opacity(0.12))
        case .context: (" ", .white.opacity(0.7), .clear)
        case .hunk:    ("", .white.opacity(0.4), .clear)
        }
        return Text(prefix + line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(fg)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(bg)
            .textSelection(.enabled)
    }

    static let addedColor = Color(red: 0.31, green: 0.84, blue: 0.55)
    static let removedColor = Color(red: 0.95, green: 0.33, blue: 0.37)
}
