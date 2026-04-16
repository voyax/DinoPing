import AgentPulseCore
import SwiftUI

/// Read-only card surfacing a Claude `AskUserQuestion` invocation.
///
/// The actual answer is collected in the terminal that hosts the agent;
/// this view is purely informational + a one-tap shortcut to bring that
/// terminal to the front. Visual language is deliberately blue/cyan to
/// distinguish it from the orange permission card — different colour =
/// different mental model (info vs. action required).
struct QuestionBanner: View {
    let question: AskUserQuestion
    let agentDisplayName: String
    let onJump: () -> Void

    @State private var appeared = false

    static let accent = Color(red: 0.36, green: 0.72, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(Self.accent)
                    .font(.system(size: 12, weight: .semibold))

                Text(headerText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.accent)

                Spacer()

                if question.questions.count > 1 {
                    Text("\(question.questions.count) questions")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Body — list each question with its options
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(question.questions.enumerated()), id: \.offset) { _, q in
                    questionBlock(q)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Single CTA — answering happens in the terminal
            Button(action: onJump) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Answer in terminal")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Self.accent.opacity(0.22))
                .foregroundStyle(Self.accent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(
            // Single shape: filled background + a 2.5pt left accent rule.
            // The accent bar gives a non-color shape signal so the banner
            // reads as "child element of this card" instead of a free-floating
            // alternate card. We deliberately drop the full rounded stroke —
            // a stroked shape inside another stroked card creates a "card-in-
            // card" visual that fights the parent.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Self.accent.opacity(0.08))
                Rectangle()
                    .fill(Self.accent.opacity(0.55))
                    .frame(width: 2.5)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10, bottomLeadingRadius: 10,
                            bottomTrailingRadius: 0, topTrailingRadius: 0
                        )
                    )
            }
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .animation(.spring(duration: 0.3), value: appeared)
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private func questionBlock(_ q: AskUserQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Question header (subtitle) — only shown when multiple questions
            // would otherwise blur into one another.
            if let header = q.header, !header.isEmpty, question.questions.count > 1 {
                Text(header)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .textCase(.uppercase)
            }

            // The question text itself
            Text(q.question)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            // Options (read-only preview). With a single question we can
            // afford to show option descriptions; with multiple questions
            // the card gets too tall, so collapse to label-only.
            if !q.options.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("·")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Self.accent.opacity(0.7))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(opt.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.78))
                                if question.questions.count == 1,
                                   let desc = opt.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var headerText: String {
        if question.questions.count == 1, let header = question.questions[0].header, !header.isEmpty {
            return header
        }
        return "\(agentDisplayName) is asking"
    }
}
