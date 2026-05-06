import Testing
@testable import AgentPulseCore

@Suite("AskUserQuestion.parse")
struct AskUserQuestionTests {
    @Test func parsesValidPayload() {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Which theme?",
                    "header": "Choose a theme",
                    "multiSelect": false,
                    "options": [
                        ["label": "Dark", "description": "Dark mode"],
                        ["label": "Light", "description": nil as String? as Any],
                    ] as [[String: Any]]
                ] as [String: Any]
            ] as [[String: Any]]
        ]
        let result = AskUserQuestion.parse(from: input)
        #expect(result != nil)
        #expect(result?.questions.count == 1)
        #expect(result?.questions[0].question == "Which theme?")
        #expect(result?.questions[0].header == "Choose a theme")
        #expect(result?.questions[0].multiSelect == false)
        #expect(result?.questions[0].options.count == 2)
        #expect(result?.questions[0].options[0].label == "Dark")
        #expect(result?.questions[0].options[0].description == "Dark mode")
    }

    @Test func parsesMultipleQuestions() {
        let input: [String: Any] = [
            "questions": [
                ["question": "First?", "options": []] as [String: Any],
                ["question": "Second?", "options": []] as [String: Any],
            ] as [[String: Any]]
        ]
        let result = AskUserQuestion.parse(from: input)
        #expect(result?.questions.count == 2)
    }

    @Test func returnsNilForEmptyQuestions() {
        let input: [String: Any] = ["questions": [] as [[String: Any]]]
        #expect(AskUserQuestion.parse(from: input) == nil)
    }

    @Test func returnsNilForMissingKey() {
        let input: [String: Any] = ["other": "stuff"]
        #expect(AskUserQuestion.parse(from: input) == nil)
    }

    @Test func returnsNilForEmptyQuestionText() {
        let input: [String: Any] = [
            "questions": [["question": "", "options": []] as [String: Any]] as [[String: Any]]
        ]
        #expect(AskUserQuestion.parse(from: input) == nil)
    }

    @Test func skipsOptionsWithEmptyLabel() {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Pick",
                    "options": [
                        ["label": "", "description": "bad"],
                        ["label": "Good", "description": "ok"],
                    ] as [[String: Any]]
                ] as [String: Any]
            ] as [[String: Any]]
        ]
        let result = AskUserQuestion.parse(from: input)
        #expect(result?.questions[0].options.count == 1)
        #expect(result?.questions[0].options[0].label == "Good")
    }

    @Test func defaultsMultiSelectToFalse() {
        let input: [String: Any] = [
            "questions": [
                ["question": "Pick", "options": []] as [String: Any]
            ] as [[String: Any]]
        ]
        let result = AskUserQuestion.parse(from: input)
        #expect(result?.questions[0].multiSelect == false)
    }

    @Test func placeholderIsValid() {
        let p = AskUserQuestion.placeholder
        #expect(p.questions.count == 1)
        #expect(!p.questions[0].question.isEmpty)
    }
}
