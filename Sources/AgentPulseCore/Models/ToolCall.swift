import Foundation

public struct ToolCall: Identifiable, Sendable {
    public let id: String
    public let toolName: String
    public let toolInput: [String: AnyCodable]
    public let startTime: Date
    public var endTime: Date?
    public var status: Status

    public enum Status: Sendable {
        case running
        case succeeded
        case failed(String)
    }

    public var displayDescription: String {
        let input = toolInput
        switch toolName {
        case "Bash":
            let cmd = input["command"]?.stringValue ?? ""
            let short = cmd.count > 60 ? String(cmd.prefix(57)) + "..." : cmd
            return "$ \(short)"
        case "Write":
            return "Write: \(lastComponent(input["file_path"]?.stringValue))"
        case "Read":
            return "Read: \(lastComponent(input["file_path"]?.stringValue))"
        case "Edit":
            return "Edit: \(lastComponent(input["file_path"]?.stringValue))"
        case "Glob":
            return "Search: \(input["pattern"]?.stringValue ?? "")"
        case "Grep":
            return "Grep: \(input["pattern"]?.stringValue ?? "")"
        case "Agent":
            return "Agent: \(input["description"]?.stringValue ?? "")"
        default:
            return toolName
        }
    }

    private func lastComponent(_ path: String?) -> String {
        guard let path else { return "?" }
        return (path as NSString).lastPathComponent
    }
}
