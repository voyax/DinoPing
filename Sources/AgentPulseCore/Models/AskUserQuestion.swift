import Foundation

/// Represents a Claude Code `AskUserQuestion` tool invocation.
///
/// `AskUserQuestion` is structurally a tool call but semantically a *prompt
/// to the human*. We surface it in the notch as a read-only "question card"
/// (not as a permission card) — Claude Code itself collects the answer in
/// the terminal where the agent is running.
public struct AskUserQuestion: Sendable, Equatable {
    public let questions: [Question]

    public struct Question: Sendable, Equatable {
        public let question: String
        public let header: String?
        public let multiSelect: Bool
        public let options: [Option]
    }

    public struct Option: Sendable, Equatable {
        public let label: String
        public let description: String?
    }

    /// Surfaced when the bridge gives us an AskUserQuestion payload we can't
    /// decode — better to show *something* than auto-allow silently and leave
    /// the user wondering why Claude is hung in the terminal.
    public static let placeholder = AskUserQuestion(questions: [
        Question(
            question: "Claude is asking you a question — answer in the terminal.",
            header: nil,
            multiSelect: false,
            options: []
        )
    ])

    /// Parse the `tool_input` payload Claude Code sends for AskUserQuestion.
    /// Returns nil if the payload doesn't look like AskUserQuestion's shape —
    /// callers should fall back to silent auto-allow in that case.
    ///
    /// Wire format (observed from a real session):
    /// ```json
    /// { "questions": [
    ///     { "question": "…", "header": "…", "multiSelect": false,
    ///       "options": [ { "label": "…", "description": "…" } ] }
    /// ] }
    /// ```
    public static func parse(from toolInput: [String: Any]) -> AskUserQuestion? {
        guard let rawQuestions = toolInput["questions"] as? [[String: Any]],
              !rawQuestions.isEmpty else {
            return nil
        }

        let parsed: [Question] = rawQuestions.compactMap { raw in
            guard let questionText = raw["question"] as? String, !questionText.isEmpty else {
                return nil
            }
            let header = raw["header"] as? String
            let multiSelect = (raw["multiSelect"] as? Bool) ?? false
            let rawOptions = raw["options"] as? [[String: Any]] ?? []
            let options: [Option] = rawOptions.compactMap { o in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, description: o["description"] as? String)
            }
            return Question(
                question: questionText,
                header: header,
                multiSelect: multiSelect,
                options: options
            )
        }

        guard !parsed.isEmpty else { return nil }
        return AskUserQuestion(questions: parsed)
    }
}
