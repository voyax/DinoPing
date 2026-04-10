import Foundation

/// AgentPulseBridge: CLI binary invoked by AI agent hooks.
///
/// Reads hook JSON from stdin, POSTs to running AgentPulse app,
/// waits for user decision, writes response JSON to stdout.
///
/// Usage: agentpulse-bridge --agent claude|codex|gemini|cursor
///
/// Fail-open: if AgentPulse app is not running, exits silently (exit 0)
/// so the agent falls back to its normal terminal dialog.

let args = CommandLine.arguments
let agentFlag = args.firstIndex(of: "--agent").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "claude"
let port = Int(ProcessInfo.processInfo.environment["AGENTPULSE_PORT"] ?? "21477") ?? 21477
let baseURL = "http://127.0.0.1:\(port)"

// Read all of stdin
let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard !inputData.isEmpty else { exit(0) }

// Determine the endpoint based on agent type and event
let endpoint = "\(baseURL)/api/approve"

// POST to AgentPulse app
var request = URLRequest(url: URL(string: endpoint)!)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue(agentFlag, forHTTPHeaderField: "X-Agent-Type")
request.httpBody = inputData
request.timeoutInterval = 120 // 2 minutes max wait for user decision

let semaphore = DispatchSemaphore(value: 0)
var responseData: Data?

let task = URLSession.shared.dataTask(with: request) { data, response, error in
    if let error {
        // Fail-open: app not running or network error → exit silently
        FileHandle.standardError.write("agentpulse-bridge: \(error.localizedDescription)\n".data(using: .utf8)!)
        semaphore.signal()
        return
    }
    responseData = data
    semaphore.signal()
}
task.resume()
semaphore.wait()

// If we got a response, write it to stdout for the agent to read
if let data = responseData, !data.isEmpty {
    FileHandle.standardOutput.write(data)
}

// Exit 0 = success (agent reads stdout for decision)
// If no response data, agent gets no decision → falls back to terminal dialog
exit(0)
