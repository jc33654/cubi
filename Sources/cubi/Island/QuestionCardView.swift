import SwiftUI
import CubiKit

/// AskUserQuestion: one question at a time, answers collected, submitted after the last one.
struct QuestionCardView: View {
    let card: PendingCard
    let questions: [AskQuestion]
    let decide: (Decision) -> Void

    @State private var index = 0
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
            Text(current.question)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                ForEach(current.options, id: \.label) { option in
                    Button { choose(option.label) } label: {
                        HStack(spacing: 8) {
                            if current.multiSelect {
                                Image(systemName: picked.contains(option.label) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                                if !option.description.isEmpty {
                                    Text(option.description).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(picked.contains(option.label) ? 0.2 : 0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
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
        if index + 1 < questions.count {
            index += 1
        } else {
            decide(.answers(answers))
        }
    }
}
