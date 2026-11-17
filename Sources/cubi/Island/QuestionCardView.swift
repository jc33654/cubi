import SwiftUI
import CubiKit

/// AskUserQuestion: one question at a time, answers collected, submitted after the last one.
struct QuestionCardView: View {
    let card: PendingCard
    let questions: [AskQuestion]
    /// The most the question and its options may take before they scroll (the island's room).
    var maxBodyHeight: CGFloat = 400
    let decide: (Decision) -> Void

    @State private var index = 0
    /// Options whose description is shown whole (one line until tapped).
    @State private var opened: Set<String> = []
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []

    private var current: AskQuestion { questions[min(index, questions.count - 1)] }

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
                if !current.header.isEmpty {
                    Text(current.header)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                Spacer()
                if questions.count > 1 {
                    Text("\(index + 1) / \(questions.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            // The whole question, and every option, scroll when they do not fit; the buttons stay.
            CappedScroll(maxHeight: maxBodyHeight) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.question)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 4) {
                        ForEach(current.options, id: \.label) { option in optionRow(option) }
                    }
                }
            }
            Text("要自訂回答請按「在終端回答」")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
            HStack {
                CardButton(title: "在終端回答", role: .quiet) { decide(.deferToTerminal) }
                Spacer()
                if current.multiSelect {
                    CardButton(title: index + 1 < questions.count ? "下一題" : "送出", role: .primary) { commit() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// About what one line of a description holds on the narrowest island.
    private static let oneLine = 40

    private func optionRow(_ option: AskQuestion.Option) -> some View {
        let open = opened.contains(option.label)
        return HStack(alignment: .top, spacing: 4) {
            Button { choose(option.label) } label: {
                HStack(alignment: .top, spacing: 8) {
                    if current.multiSelect {
                        Image(systemName: picked.contains(option.label) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if !option.description.isEmpty {
                            Text(option.description).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                                .lineLimit(open ? nil : 1)
                                .fixedSize(horizontal: false, vertical: open)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Only where it may not fit one line (a guess by length: a needless arrow does no harm).
            if option.description.count > Self.oneLine {
                Button { if open { opened.remove(option.label) } else { opened.insert(option.label) } } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "收起說明" : "看完整說明")
                .padding(.top, 3).padding(.trailing, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(picked.contains(option.label) ? 0.2 : 0.08)))
    }

    private func choose(_ label: String) {
        if current.multiSelect {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            picked = [label]
            commit()
        }
    }

    private func commit() {
        answers[current.question] = picked.sorted().joined(separator: ", ")
        picked = []
        opened = []
        if index + 1 < questions.count {
            index += 1
        } else {
            decide(.answers(answers))
        }
    }
}

/// Its content at its own height, up to `maxHeight`; past that the content scrolls. Sized in one
/// layout pass (a hidden copy is measured), so the card's first frame is already right.
private struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.drawsScrollContentFlat) private var flat

    var body: some View {
        CappedHeight(maxHeight: maxHeight) {
            content.fixedSize(horizontal: false, vertical: true).hidden()
            if flat {
                Color.clear.overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true) }.clipped()
            } else {
                ScrollView { content }.scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

/// Offline renders (ImageRenderer draws no scroll view): the same layout, the content drawn as it
/// is and cut at the bottom.
private struct DrawsScrollContentFlat: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var drawsScrollContentFlat: Bool {
        get { self[DrawsScrollContentFlat.self] }
        set { self[DrawsScrollContentFlat.self] = newValue }
    }
}

/// Two subviews: the first is measured, the second is shown at that height, capped.
private struct CappedHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, max(0, maxHeight)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: 0))
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
